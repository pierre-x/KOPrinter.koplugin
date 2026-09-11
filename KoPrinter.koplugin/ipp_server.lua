--[[--
Non-blocking IPP-over-HTTP server (RFC 8010, RFC 8011).

The server never blocks: `poll()` is meant to be called from the KOReader
main loop, the same way the mDNS responder and the HTTP inspector plugin do
it, so the UI keeps running while a job is transferred.

Documents are streamed straight to a spool file as the bytes arrive instead
of being buffered, because a print job can be tens of megabytes and an
e-reader has little memory to spare.

@module koplugin.KOPrinter.ipp_server
--]]

local IPP = require("ipp_message")
local Urf = require("urf")

local Server = {}
Server.__index = Server

local READ_CHUNK = 32768
-- A client that stops talking mid-request has its connection dropped.
local IDLE_TIMEOUT = 60
-- IPP attributes always come before the document, and are never this big;
-- the cap stops a malformed request from eating all the memory.
local MAX_ATTRIBUTES_SIZE = 512 * 1024
local MAX_CONNECTIONS = 8
local MAX_HEADER_SIZE = 16 * 1024

local silent_logger = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}

local HTTP_REASONS = {
    [100] = "Continue", [200] = "OK", [400] = "Bad Request", [404] = "Not Found",
    [405] = "Method Not Allowed", [413] = "Request Entity Too Large",
    [415] = "Unsupported Media Type", [500] = "Internal Server Error",
    [501] = "Not Implemented",
}

--- Creates a server. Nothing is opened until `start()`.
-- @tparam table opts
--   printer: an ipp_printer instance;
--   port, address: where to listen;
--   spool_dir: directory receiving the documents;
--   on_job: function(job) called once a document is fully received;
--   socket: LuaSocket replacement, for tests;
--   logger, clock: as in the mDNS responder.
function Server.new(opts)
    local self = setmetatable({}, Server)
    self.opts = opts or {}
    self.printer = assert(self.opts.printer, "printer is required")
    self.port = tonumber(self.opts.port) or self.printer.port or 631
    self.address = self.opts.address or "*"
    self.spool_dir = self.opts.spool_dir or "/tmp"
    self.on_job = self.opts.on_job
    self.logger = self.opts.logger or silent_logger
    self.clock = self.opts.clock or os.time
    self.socket = self.opts.socket
    self.connections = {}
    self.jobs = {}
    self.next_job_id = 1
    self.stats = { requests = 0, jobs = 0, bytes = 0, errors = 0 }
    return self
end

local function loadSocket(self)
    if self.socket then
        return self.socket
    end
    self.socket = require("socket")
    return self.socket
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

--- Binds and starts listening.
-- @treturn boolean|nil true, or nil plus an error message
function Server:start()
    if self.listener then
        return true
    end
    local socket = loadSocket(self)
    -- Same constructor as KOReader's SimpleTCPServer (the HTTP inspector):
    -- socket.bind() owns SO_REUSEADDR and listen(). tcp4()+bind() appeared
    -- to succeed on a Kindle and then left no listening fd behind.
    local host = self.address == "*" and "*" or self.address
    local listener, err = socket.bind(host, self.port, MAX_CONNECTIONS)
    if not listener then
        return nil, string.format("cannot bind port %d: %s", self.port, tostring(err))
    end
    -- 10 ms, matching SimpleTCPServer. A zero timeout has been seen to make
    -- the listen socket vanish on Kindle's LuaSocket.
    listener:settimeout(0.01)
    self.listener = listener
    self.printer.start_time = self.clock()
    self.logger.info(string.format("KoPrinter: IPP server listening on %s:%d", self.address, self.port))
    return true
end

--- Closes every connection and the listening socket.
function Server:stop()
    for _, conn in ipairs(self.connections) do
        self:closeConnection(conn)
    end
    self.connections = {}
    if self.listener then
        self.listener:close()
        self.listener = nil
        self.logger.info("KOPrinter: IPP server stopped")
    end
end

function Server:isRunning()
    return self.listener ~= nil
end

--- Snapshot for the UI.
function Server:getStatus()
    return {
        running = self:isRunning(),
        port = self.port,
        connections = #self.connections,
        jobs = #self.jobs,
        stats = self.stats,
    }
end

-------------------------------------------------------------------------------
-- Connections
-------------------------------------------------------------------------------

local function newConnection(sock, now)
    return {
        sock = sock,
        phase = "headers",
        inbox = "",
        outbox = "",
        last_activity = now,
        keep_alive = true,
    }
end

function Server:closeConnection(conn)
    if conn.doc_file then
        conn.doc_file:close()
        conn.doc_file = nil
        -- A half-written spool file is of no use to anybody.
        if conn.doc_path and not conn.doc_complete then
            os.remove(conn.doc_path)
        end
    end
    if conn.sock then
        conn.sock:close()
        conn.sock = nil
    end
end

function Server:removeConnection(conn)
    self:closeConnection(conn)
    for i, c in ipairs(self.connections) do
        if c == conn then
            table.remove(self.connections, i)
            break
        end
    end
end

--- Queues bytes; they leave in `flush`, which tolerates partial writes.
local function queue(conn, data)
    conn.outbox = conn.outbox .. data
end

local function flush(conn)
    if conn.outbox == "" then
        return true
    end
    local sent, err, last = conn.sock:send(conn.outbox)
    if sent then
        conn.outbox = conn.outbox:sub(sent + 1)
        return true
    end
    if err == "timeout" then
        conn.outbox = conn.outbox:sub((last or 0) + 1)
        return true
    end
    return false, err
end

-------------------------------------------------------------------------------
-- HTTP
-------------------------------------------------------------------------------

local function httpResponse(status, content_type, body, keep_alive)
    body = body or ""
    return table.concat({
        string.format("HTTP/1.1 %d %s\r\n", status, HTTP_REASONS[status] or "Unknown"),
        content_type and ("Content-Type: " .. content_type .. "\r\n") or "",
        string.format("Content-Length: %d\r\n", #body),
        "Connection: " .. (keep_alive and "keep-alive" or "close") .. "\r\n",
        "\r\n",
        body,
    })
end

local function hexPrefix(data, n)
    local bytes = {}
    for i = 1, math.min(n or 24, #data) do
        bytes[#bytes + 1] = string.format("%02X", data:byte(i))
    end
    return table.concat(bytes, " ")
end

--- End of the HTTP header block. iOS sometimes uses LF-only separators.
local function splitHead(inbox)
    local crlf = inbox:find("\r\n\r\n", 1, true)
    if crlf then
        return inbox:sub(1, crlf + 3), inbox:sub(crlf + 4)
    end
    local lf = inbox:find("\n\n", 1, true)
    if lf then
        return inbox:sub(1, lf + 1), inbox:sub(lf + 2)
    end
    return nil, inbox
end

--- Parses the request line and headers. Header names are lowercased.
local function parseHead(head)
    head = head:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in head:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local method, path, version = (lines[1] or ""):match("^(%u+)%s+(%S+)%s+HTTP/(%d%.%d)$")
    if not method then
        return nil
    end
    local headers = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([^:]+):%s*(.-)%s*$")
        if name then
            headers[name:lower()] = value
        end
    end
    return { method = method, path = path, version = version, headers = headers }
end

--- Sends a response and gets the connection ready for the next request.
-- Returns true so that callers can `return self:respond(...)`.
function Server:respond(conn, status, content_type, body)
    queue(conn, httpResponse(status, content_type, body, conn.keep_alive))
    conn.phase = conn.keep_alive and "headers" or "closing"
    conn.request = nil
    conn.ipp_request = nil
    conn.body_buf = nil
    conn.doc_file = nil
    conn.doc_path = nil
    conn.doc_complete = nil
    conn.job = nil
    return true
end

local function statusPage(self)
    local w, h = self.printer:sizeMM()
    return table.concat({
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">",
        "<title>", self.printer.name, "</title>",
        "<style>body{font:14px -apple-system,sans-serif;margin:2em;max-width:34em}",
        "td{padding:.2em .8em .2em 0}</style></head><body>",
        "<h1>", self.printer.name, "</h1>",
        "<p>KOReader screen exposed as an IPP printer.</p><table>",
        string.format("<tr><td>Screen</td><td>%d x %d px at %d dpi</td></tr>",
            self.printer.width_px, self.printer.height_px, self.printer.dpi),
        string.format("<tr><td>Page</td><td>%.2f x %.2f mm (%s)</td></tr>", w, h, self.printer.media_name),
        string.format("<tr><td>Colour</td><td>%s</td></tr>", self.printer.color and "yes" or "no"),
        string.format("<tr><td>Format</td><td>application/pdf</td></tr>"),
        string.format("<tr><td>URI</td><td>%s</td></tr>", self.printer:uri()),
        string.format("<tr><td>Jobs received</td><td>%d</td></tr>", self.stats.jobs),
        "</table></body></html>",
    })
end

function Server:handleRequest(conn)
    local request = conn.request
    self.stats.requests = self.stats.requests + 1

    if request.method == "GET" or request.method == "HEAD" then
        return self:respond(conn, 200, "text/html; charset=utf-8",
            request.method == "HEAD" and "" or statusPage(self))
    end
    if request.method == "OPTIONS" then
        return self:respond(conn, 200, nil, "")
    end
    if request.method ~= "POST" then
        return self:respond(conn, 405, "text/plain", "Method not allowed\n")
    end

    local content_type = (request.headers["content-type"] or ""):lower()
    -- iOS AirPrint has been seen to omit the type or send octet-stream.
    local ipp_body = content_type == ""
        or content_type:find("ipp", 1, true)
        or content_type:find("octet-stream", 1, true)
        or content_type:find("urf", 1, true)
    if not ipp_body then
        self.logger.warn("KOPrinter: refused " .. request.method .. " "
            .. tostring(request.path) .. " Content-Type=" .. content_type)
        return self:respond(conn, 415, "text/plain", "Expected application/ipp\n")
    end
    -- The body is consumed by readBody, which calls handleIPP when the
    -- attributes are complete and again when the document ends.
    conn.phase = "body"
    conn.body_buf = ""
    return true
end

-------------------------------------------------------------------------------
-- Body reading: Content-Length or chunked, document streamed to disk
-------------------------------------------------------------------------------

--- Pulls whatever is decodable out of a chunked stream, leaving the rest in
-- `conn.inbox` for the next poll.
local function dechunk(conn)
    local out = {}
    while true do
        if conn.chunk_trailers then
            -- After the zero-sized chunk come optional trailer fields and
            -- then an empty line. Consuming it matters: anything left over
            -- would be read as the start of the next keep-alive request.
            local line_end = conn.inbox:find("\r\n", 1, true)
            if not line_end then
                break
            end
            local line = conn.inbox:sub(1, line_end - 1)
            conn.inbox = conn.inbox:sub(line_end + 2)
            if line == "" then
                conn.chunk_trailers = nil
                conn.body_done = true
                break
            end
        elseif conn.chunk_remaining and conn.chunk_remaining > 0 then
            if #conn.inbox == 0 then
                break
            end
            local take = math.min(conn.chunk_remaining, #conn.inbox)
            out[#out + 1] = conn.inbox:sub(1, take)
            conn.inbox = conn.inbox:sub(take + 1)
            conn.chunk_remaining = conn.chunk_remaining - take
        elseif conn.chunk_remaining == 0 then
            -- Trailing CRLF of the chunk just read.
            if #conn.inbox < 2 then
                break
            end
            conn.inbox = conn.inbox:sub(3)
            conn.chunk_remaining = nil
        else
            local line_end = conn.inbox:find("\r\n", 1, true)
            if not line_end then
                if #conn.inbox > 1024 then
                    return nil, "malformed chunk size"
                end
                break
            end
            local header = conn.inbox:sub(1, line_end - 1)
            local size = tonumber((header:match("^%x+")) or "", 16)
            if not size then
                return nil, "malformed chunk size"
            end
            conn.inbox = conn.inbox:sub(line_end + 2)
            if size == 0 then
                conn.chunk_trailers = true
            else
                conn.chunk_remaining = size
            end
        end
    end
    return table.concat(out)
end

--- Feeds body bytes forward: first into the IPP attribute buffer, then, once
-- the attributes are parsed, straight into the spool file.
function Server:consumeBody(conn, data)
    if #data == 0 then
        return true
    end
    if not conn.ipp_request then
        conn.body_buf = conn.body_buf .. data
        if #conn.body_buf > MAX_ATTRIBUTES_SIZE then
            return nil, "IPP attributes too large"
        end
        local message, err = IPP.decode(conn.body_buf)
        if not message then
            if err == "incomplete" then
                return true
            end
            return nil, "malformed IPP request: " .. tostring(err)
        end
        conn.ipp_request = message
        local document = conn.body_buf:sub(message.data_offset)
        conn.body_buf = nil
        local ok, dispatch_err = self:dispatch(conn, message)
        if not ok then
            return nil, dispatch_err
        end
        data = document
        if #data == 0 then
            return true
        end
    end
    if conn.doc_file then
        local ok, write_err = conn.doc_file:write(data)
        if not ok then
            return nil, "cannot write spool file: " .. tostring(write_err)
        end
        conn.doc_bytes = (conn.doc_bytes or 0) + #data
        self.stats.bytes = self.stats.bytes + #data
    end
    return true
end

function Server:readBody(conn)
    local request = conn.request
    if not conn.body_mode then
        local encoding = (request.headers["transfer-encoding"] or ""):lower()
        if encoding:find("chunked", 1, true) then
            conn.body_mode = "chunked"
        else
            conn.body_mode = "length"
            conn.body_remaining = tonumber(request.headers["content-length"]) or 0
        end
        conn.body_done = false
    end

    local data
    if conn.body_mode == "chunked" then
        local err
        data, err = dechunk(conn)
        if not data then
            return nil, err
        end
    else
        local take = math.min(conn.body_remaining, #conn.inbox)
        data = conn.inbox:sub(1, take)
        conn.inbox = conn.inbox:sub(take + 1)
        conn.body_remaining = conn.body_remaining - take
        if conn.body_remaining == 0 then
            conn.body_done = true
        end
    end

    local ok, err = self:consumeBody(conn, data)
    if not ok then
        return nil, err
    end

    if conn.body_done then
        return self:finishRequest(conn)
    end
    return true
end

--- Called once the whole body has arrived: closes the document and answers.
function Server:finishRequest(conn)
    if not conn.ipp_request then
        return nil, "request ended before its IPP attributes were complete"
    end
    if conn.doc_file then
        conn.doc_file:close()
        conn.doc_file = nil
        conn.doc_complete = true
        self:completeJob(conn.job, conn.doc_bytes or 0)
    end
    local response = conn.response
    conn.response = nil
    if not response then
        return nil, "no response was prepared"
    end
    -- The job attributes are only final once the document has landed.
    if conn.job then
        self:fillJobResponse(response, conn.job)
    end
    self:respond(conn, 200, "application/ipp", IPP.encode(response))
    return true
end

-------------------------------------------------------------------------------
-- Polling
-------------------------------------------------------------------------------

function Server:acceptConnections(now)
    while #self.connections < MAX_CONNECTIONS do
        local sock = self.listener:accept()
        if not sock then
            return
        end
        sock:settimeout(0)
        sock:setoption("tcp-nodelay", true)
        local conn = newConnection(sock, now)
        local ip, port = sock:getpeername()
        conn.peer = ip and string.format("%s:%s", ip, tostring(port)) or "?"
        self.logger.info("KOPrinter: client " .. conn.peer)
        self.connections[#self.connections + 1] = conn
    end
end

function Server:serviceConnection(conn, now)
    local data, err, partial = conn.sock:receive(READ_CHUNK)
    local received = data or partial
    if received and #received > 0 then
        if not conn.hello_logged then
            conn.hello_logged = true
            local first = received:byte(1)
            if first == 0x16 then
                self.logger.warn("KOPrinter: TLS handshake from " .. (conn.peer or "?")
                    .. " — iOS is trying IPPS on a plain IPP port")
            elseif received:sub(1, 3) == "PRI" then
                self.logger.warn("KOPrinter: HTTP/2 preface from " .. (conn.peer or "?"))
            else
                self.logger.info(string.format("KOPrinter: %s hello %d bytes [%s]",
                    conn.peer or "?", #received, hexPrefix(received, 24)))
            end
        end
        conn.inbox = conn.inbox .. received
        conn.last_activity = now
    end
    local closed = (err == "closed")

    while true do
        if conn.phase == "headers" then
            local head
            head, conn.inbox = splitHead(conn.inbox)
            if not head then
                if #conn.inbox > MAX_HEADER_SIZE then
                    self:respond(conn, 413, "text/plain", "Headers too large\n")
                    conn.keep_alive = false
                end
                break
            end
            local request = parseHead(head)
            if not request then
                self.logger.warn("KOPrinter: malformed HTTP from "
                    .. (conn.peer or "?") .. " [" .. hexPrefix(head, 32) .. "]")
                self:respond(conn, 400, "text/plain", "Malformed request\n")
                conn.keep_alive = false
                break
            end
            self.logger.info(string.format("KOPrinter: %s %s %s",
                request.method, request.path, request.headers["content-type"] or "-"))
            conn.request = request
            conn.keep_alive = (request.version == "1.1")
                and (request.headers["connection"] or ""):lower() ~= "close"
            conn.body_mode = nil
            conn.chunk_remaining = nil
            conn.chunk_trailers = nil
            conn.doc_bytes = 0
            -- CUPS waits for this before sending a job body.
            if (request.headers["expect"] or ""):lower():find("100-continue", 1, true) then
                queue(conn, "HTTP/1.1 100 Continue\r\n\r\n")
            end
            local ok, handle_err = self:handleRequest(conn)
            if not ok then
                self.logger.warn("KOPrinter: " .. tostring(handle_err))
                self:respond(conn, 400, "text/plain", "Bad request\n")
                conn.keep_alive = false
                break
            end
        elseif conn.phase == "body" then
            local before = #conn.inbox
            local ok, body_err = self:readBody(conn)
            if not ok then
                self.stats.errors = self.stats.errors + 1
                self.logger.warn("KOPrinter: " .. tostring(body_err))
                self:respond(conn, 400, "text/plain", "Bad request\n")
                conn.keep_alive = false
                break
            end
            -- Nothing consumed and nothing new to consume: wait for more.
            if conn.phase == "body" and #conn.inbox == before then
                break
            end
        else
            break
        end
    end

    if not flush(conn) then
        return false
    end
    if conn.phase == "closing" and conn.outbox == "" then
        return false
    end
    if closed then
        -- A client may close right after a complete request; only drop the
        -- connection once everything queued has left.
        return conn.outbox ~= "" or conn.phase == "body"
    end
    if now - conn.last_activity > IDLE_TIMEOUT then
        self.logger.dbg("KOPrinter: dropping idle connection")
        return false
    end
    return true
end

--- One non-blocking pass over the listener and every open connection.
function Server:poll()
    if not self.listener then
        return
    end
    local now = self.clock()
    self:acceptConnections(now)
    local i = 1
    while i <= #self.connections do
        local conn = self.connections[i]
        local ok, keep = pcall(self.serviceConnection, self, conn, now)
        if not ok then
            self.stats.errors = self.stats.errors + 1
            self.logger.err("KOPrinter: connection error: " .. tostring(keep))
            keep = false
        end
        if keep then
            i = i + 1
        else
            self:removeConnection(conn)
        end
    end
end

-------------------------------------------------------------------------------
-- Jobs
-------------------------------------------------------------------------------

--- Turns a job name into something safe to put in a file name.
local function sanitizeFilename(name)
    name = tostring(name or ""):gsub("[/\\%z\n\r]", "-"):gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 80 then
        name = name:sub(1, 80)
    end
    return name
end

function Server:createJob(request)
    local job = {
        id = self.next_job_id,
        name = sanitizeFilename(IPP.getValue(request, "job-name", "Untitled")),
        user = tostring(IPP.getValue(request, "requesting-user-name", "anonymous")),
        format = tostring(IPP.getValue(request, "document-format", "application/pdf")),
        state = IPP.JOB_PENDING,
        state_reasons = { "job-incoming" },
        created = self.clock(),
        size = 0,
    }
    if job.name == "" then
        job.name = "Untitled"
    end
    job.uri = string.format("%s/%d", self.printer:uri(), job.id)
    self.next_job_id = self.next_job_id + 1
    self.jobs[#self.jobs + 1] = job
    self.printer.queued_job_count = self.printer.queued_job_count + 1
    return job
end

function Server:findJob(id)
    for _, job in ipairs(self.jobs) do
        if job.id == id then
            return job
        end
    end
    return nil
end

--- Job id from either `job-id` or a `job-uri` ending in the id.
local function requestedJobId(request)
    local id = IPP.getValue(request, "job-id")
    if type(id) == "number" then
        return id
    end
    local uri = IPP.getValue(request, "job-uri")
    if type(uri) == "string" then
        return tonumber(uri:match("/(%d+)$"))
    end
    return nil
end

--- Opens the spool file a job's document will be streamed into.
function Server:openSpoolFile(conn, job)
    local format = (job.format or ""):lower()
    local extension = "bin"
    if format == "application/pdf" then
        extension = "pdf"
    elseif format:find("urf", 1, true) then
        extension = "urf"
    elseif format:find("jpeg", 1, true) then
        extension = "jpg"
    end
    local stamp = os.date("%Y-%m-%d_%H-%M-%S", job.created)
    local base = string.format("%s/%s %s", self.spool_dir, stamp, job.name)
    local path = base .. "." .. extension
    local index = 2
    while true do
        local existing = io.open(path, "rb")
        if not existing then
            break
        end
        existing:close()
        path = string.format("%s (%d).%s", base, index, extension)
        index = index + 1
    end
    local file, err = io.open(path, "wb")
    if not file then
        return nil, "cannot open spool file " .. path .. ": " .. tostring(err)
    end
    conn.doc_file = file
    conn.doc_path = path
    conn.doc_bytes = 0
    job.path = path
    job.state = IPP.JOB_PROCESSING
    job.state_reasons = { "job-printing" }
    return true
end

--- Marks a job done and hands the document over to KOReader.
function Server:completeJob(job, bytes)
    if not job then
        return
    end
    job.size = bytes
    job.state = IPP.JOB_COMPLETED
    job.state_reasons = { "job-completed-successfully" }
    job.completed = self.clock()
    self.printer.queued_job_count = math.max(self.printer.queued_job_count - 1, 0)
    self.stats.jobs = self.stats.jobs + 1
    if job.path then
        local converted, conv_err = Urf.convertFile(job.path)
        if not converted then
            job.error = conv_err or "cannot decode the received document"
            self.logger.err("KOPrinter: cannot prepare job " .. job.id .. ": " .. job.error)
        elseif converted ~= job.path then
            os.remove(job.path)
            job.path = converted
            job.format = "application/pdf"
            self.logger.info(string.format("KOPrinter: job %d converted URF to PDF: %s",
                job.id, job.path))
        end
    end
    self.logger.info(string.format("KOPrinter: job %d received, %d bytes: %s",
        job.id, bytes, tostring(job.path)))
    if self.on_job then
        local ok, err = pcall(self.on_job, job)
        if not ok then
            self.logger.err("KOPrinter: job handler failed: " .. tostring(err))
        end
    end
end

-------------------------------------------------------------------------------
-- IPP operations
-------------------------------------------------------------------------------

local function operationGroup(request)
    return {
        tag = IPP.TAG_OPERATION_ATTRIBUTES,
        attributes = {
            IPP.attr(IPP.TAG_CHARSET, "attributes-charset", "utf-8"),
            IPP.attr(IPP.TAG_NATURAL_LANGUAGE, "attributes-natural-language",
                IPP.getValue(request, "attributes-natural-language", "en")),
        },
    }
end

local function newResponse(request, status)
    -- RFC 8011 §4.1.8: answer an unsupported version with the closest one
    -- we do speak rather than echoing it back.
    local major, minor = request.version_major or 2, request.version_minor or 0
    if major < 1 or major > 2 then
        major, minor = 2, 0
    end
    return {
        version_major = major,
        version_minor = minor,
        status_code = status,
        request_id = request.request_id,
        groups = { operationGroup(request) },
    }
end

--- Every job attribute, tagged with its group so that a client's
-- `requested-attributes` can select a subset.
function Server:jobAttributes(job)
    local since_start = function(when)
        return when and math.max(when - self.printer.start_time, 0) or 0
    end
    local description = {
        IPP.attr(IPP.TAG_INTEGER, "job-id", job.id),
        IPP.attr(IPP.TAG_URI, "job-uri", job.uri),
        IPP.attr(IPP.TAG_ENUM, "job-state", job.state),
        IPP.attr(IPP.TAG_KEYWORD, "job-state-reasons", job.state_reasons),
        IPP.attr(IPP.TAG_TEXT, "job-state-message", "Sent to the screen"),
        IPP.attr(IPP.TAG_NAME, "job-name", job.name),
        IPP.attr(IPP.TAG_NAME, "job-originating-user-name", job.user),
        IPP.attr(IPP.TAG_URI, "job-printer-uri", self.printer:uri()),
        IPP.attr(IPP.TAG_INTEGER, "job-k-octets", math.ceil((job.size or 0) / 1024)),
        IPP.attr(IPP.TAG_INTEGER, "job-impressions-completed",
            job.state == IPP.JOB_COMPLETED and 1 or 0),
        IPP.attr(IPP.TAG_INTEGER, "number-of-documents", job.path and 1 or 0),
        IPP.attr(IPP.TAG_INTEGER, "time-at-creation", since_start(job.created)),
        IPP.attr(IPP.TAG_INTEGER, "time-at-processing", since_start(job.created)),
        IPP.attr(IPP.TAG_INTEGER, "time-at-completed", since_start(job.completed)),
        IPP.attr(IPP.TAG_INTEGER, "job-printer-up-time", self.printer:upTime(self.clock())),
    }
    local template = {
        IPP.attr(IPP.TAG_INTEGER, "copies", 1),
        IPP.attr(IPP.TAG_KEYWORD, "media", self.printer.media_name),
        IPP.attr(IPP.TAG_KEYWORD, "sides", "one-sided"),
        IPP.attr(IPP.TAG_MIME_MEDIA_TYPE, "document-format", job.format),
    }
    local out = {}
    for _, attr in ipairs(description) do
        out[#out + 1] = { group = "job-description", attr = attr }
    end
    for _, attr in ipairs(template) do
        out[#out + 1] = { group = "job-template", attr = attr }
    end
    return out
end

--- Picks the job attributes a client asked for. `defaults` applies when the
-- request carries no `requested-attributes`: RFC 8011 §4.2.6 makes that
-- job-uri and job-id for Get-Jobs, but everything elsewhere.
function Server:selectJobAttributes(job, requested, defaults)
    if not requested or #requested == 0 then
        requested = defaults or { "all" }
    end
    local wanted_groups, wanted_names, want_all = {}, {}, false
    for _, name in ipairs(requested) do
        name = tostring(name)
        if name == "all" then
            want_all = true
        elseif name == "job-description" or name == "job-template" then
            wanted_groups[name] = true
        else
            wanted_names[name] = true
        end
    end
    local selected = {}
    for _, entry in ipairs(self:jobAttributes(job)) do
        if want_all or wanted_groups[entry.group] or wanted_names[entry.attr.name] then
            selected[#selected + 1] = entry.attr
        end
    end
    return selected
end

--- Appends a job-attributes group describing `job` to a response.
function Server:addJobGroup(response, job, requested, defaults)
    response.groups[#response.groups + 1] = {
        tag = IPP.TAG_JOB_ATTRIBUTES,
        attributes = self:selectJobAttributes(job, requested, defaults),
    }
end

--- Replaces the job-attributes group of a response, used once a document
-- has landed and the job attributes are final.
function Server:fillJobResponse(response, job, requested, defaults)
    for index, group in ipairs(response.groups) do
        if group.tag == IPP.TAG_JOB_ATTRIBUTES then
            table.remove(response.groups, index)
            break
        end
    end
    self:addJobGroup(response, job, requested, defaults)
end

--- True when the printer can render this document format.
local function formatSupported(format)
    if not format or format == "" then
        return true
    end
    format = format:lower()
    return format == "application/pdf"
        or format == "application/octet-stream"
        or format == "image/urf"
        or format == "image/jpeg"
end

local SUPPORTED_VERSIONS = { ["1.0"] = true, ["1.1"] = true, ["2.0"] = true }

-- Operations addressing the printer itself, and those addressing a job.
local NEEDS_PRINTER_URI = {
    [IPP.OP_PRINT_JOB] = true, [IPP.OP_VALIDATE_JOB] = true,
    [IPP.OP_CREATE_JOB] = true, [IPP.OP_GET_JOBS] = true,
    [IPP.OP_GET_PRINTER_ATTRIBUTES] = true, [IPP.OP_IDENTIFY_PRINTER] = true,
    [IPP.OP_CANCEL_MY_JOBS] = true,
}
local NEEDS_JOB_TARGET = {
    [IPP.OP_SEND_DOCUMENT] = true, [IPP.OP_GET_JOB_ATTRIBUTES] = true,
    [IPP.OP_CANCEL_JOB] = true, [IPP.OP_CLOSE_JOB] = true,
}

--- Checks the parts of a request every operation shares (RFC 8011 §4.1).
-- @treturn number|nil a status code when the request must be rejected
local function validateRequest(request)
    local version = string.format("%d.%d", request.version_major or 0, request.version_minor or 0)
    if not SUPPORTED_VERSIONS[version] then
        return IPP.ERR_VERSION_NOT_SUPPORTED
    end
    -- §4.1.1: the request-id must be greater than zero.
    if not request.request_id or request.request_id < 1 then
        return IPP.ERR_BAD_REQUEST
    end
    -- §4.1.4: the operation group comes first and starts with exactly these
    -- two attributes, in this order.
    local group = request.groups and request.groups[1]
    if not group or group.tag ~= IPP.TAG_OPERATION_ATTRIBUTES then
        return IPP.ERR_BAD_REQUEST
    end
    local charset, language = group.attributes[1], group.attributes[2]
    if not charset or charset.name ~= "attributes-charset"
        or charset.tag ~= IPP.TAG_CHARSET then
        return IPP.ERR_BAD_REQUEST
    end
    if not language or language.name ~= "attributes-natural-language"
        or language.tag ~= IPP.TAG_NATURAL_LANGUAGE then
        return IPP.ERR_BAD_REQUEST
    end
    local cs = tostring(charset.values[1] or ""):lower()
    if cs ~= "utf-8" and cs ~= "us-ascii" then
        return IPP.ERR_CHARSET_NOT_SUPPORTED
    end
    -- §4.2: the target must be identified.
    local op = request.operation_id
    if NEEDS_PRINTER_URI[op] and not IPP.getValue(request, "printer-uri") then
        return IPP.ERR_BAD_REQUEST
    end
    if NEEDS_JOB_TARGET[op] and not IPP.getValue(request, "job-uri")
        and not (IPP.getValue(request, "printer-uri") and IPP.getValue(request, "job-id")) then
        return IPP.ERR_BAD_REQUEST
    end
    return nil
end

--- Handles a decoded request. Operations carrying a document set up the
-- spool file and leave the response for `finishRequest`; the others answer
-- straight away.
function Server:dispatch(conn, request)
    local op = request.operation_id
    local requested = {}
    for _, value in ipairs(IPP.getValues(request, "requested-attributes")) do
        requested[#requested + 1] = tostring(value)
    end
    self.logger.info(string.format("KOPrinter: %s (request-id %d) format=%s uri=%s requested=%s",
        IPP.operationName(op), request.request_id or 0,
        tostring(IPP.getValue(request, "document-format") or "-"),
        tostring(IPP.getValue(request, "printer-uri") or "-"),
        #requested > 0 and table.concat(requested, ",") or "-"))

    local rejection = validateRequest(request)
    if rejection then
        self.logger.warn(string.format("KOPrinter: rejecting %s with status 0x%04X",
            IPP.operationName(op), rejection))
        conn.response = newResponse(request, rejection)
        return true
    end

    if op == IPP.OP_GET_PRINTER_ATTRIBUTES then
        local attrs = self.printer:selectAttributes(requested, self.clock())
        local have = {}
        for _, attr in ipairs(attrs) do
            have[attr.name] = true
        end
        local missing = {}
        for _, name in ipairs(requested) do
            if name ~= "all" and name ~= "printer-description" and name ~= "job-template"
                and not have[name] then
                missing[#missing + 1] = name
            end
        end
        if #missing > 0 then
            self.logger.info("KOPrinter: GPA omitted " .. table.concat(missing, ","))
        end
        local response = newResponse(request, IPP.OK)
        response.groups[#response.groups + 1] = {
            tag = IPP.TAG_PRINTER_ATTRIBUTES,
            attributes = attrs,
        }
        conn.response = response
    elseif op == IPP.OP_VALIDATE_JOB then
        local format = IPP.getValue(request, "document-format")
        conn.response = newResponse(request,
            formatSupported(format) and IPP.OK or IPP.ERR_DOCUMENT_FORMAT_NOT_SUPPORTED)
    elseif op == IPP.OP_PRINT_JOB then
        local format = IPP.getValue(request, "document-format")
        if not formatSupported(format) then
            conn.response = newResponse(request, IPP.ERR_DOCUMENT_FORMAT_NOT_SUPPORTED)
        elseif not self.printer.accepting_jobs then
            conn.response = newResponse(request, IPP.ERR_NOT_ACCEPTING_JOBS)
        else
            local job = self:createJob(request)
            local ok, err = self:openSpoolFile(conn, job)
            if not ok then
                self:cancelJob(job)
                return nil, err
            end
            conn.job = job
            conn.response = newResponse(request, IPP.OK)
        end
    elseif op == IPP.OP_CREATE_JOB then
        if not self.printer.accepting_jobs then
            conn.response = newResponse(request, IPP.ERR_NOT_ACCEPTING_JOBS)
        else
            local job = self:createJob(request)
            local response = newResponse(request, IPP.OK)
            self:addJobGroup(response, job)
            conn.response = response
        end
    elseif op == IPP.OP_SEND_DOCUMENT then
        local job = self:findJob(requestedJobId(request) or -1)
        -- RFC 8011 §4.3.1 makes last-document mandatory.
        if type(IPP.getValue(request, "last-document")) ~= "boolean" then
            conn.response = newResponse(request, IPP.ERR_BAD_REQUEST)
        elseif not job then
            conn.response = newResponse(request, IPP.ERR_NOT_FOUND)
        elseif job.state == IPP.JOB_COMPLETED or job.state == IPP.JOB_CANCELED then
            conn.response = newResponse(request, IPP.ERR_NOT_POSSIBLE)
        else
            local name = IPP.getValue(request, "document-name")
            if type(name) == "string" and name ~= "" then
                job.name = sanitizeFilename(name)
            end
            local format = IPP.getValue(request, "document-format")
            if type(format) == "string" and format ~= "" then
                if not formatSupported(format) then
                    conn.response = newResponse(request, IPP.ERR_DOCUMENT_FORMAT_NOT_SUPPORTED)
                    return true
                end
                job.format = format
            end
            local ok, err = self:openSpoolFile(conn, job)
            if not ok then
                return nil, err
            end
            conn.job = job
            conn.response = newResponse(request, IPP.OK)
        end
    elseif op == IPP.OP_GET_JOB_ATTRIBUTES then
        local job = self:findJob(requestedJobId(request) or -1)
        if not job then
            conn.response = newResponse(request, IPP.ERR_NOT_FOUND)
        else
            local response = newResponse(request, IPP.OK)
            self:addJobGroup(response, job, requested)
            conn.response = response
        end
    elseif op == IPP.OP_GET_JOBS then
        local which = tostring(IPP.getValue(request, "which-jobs", "not-completed"))
        local limit = tonumber(IPP.getValue(request, "limit")) or math.huge
        local response = newResponse(request, IPP.OK)
        local count = 0
        for _, job in ipairs(self.jobs) do
            local completed = job.state == IPP.JOB_COMPLETED or job.state == IPP.JOB_CANCELED
            local matches = which == "all"
                or (which == "completed" and completed)
                or (which == "not-completed" and not completed)
            if matches and count < limit then
                -- RFC 8011 §4.2.6: without requested-attributes, a client
                -- only gets the job identifiers.
                self:addJobGroup(response, job, requested, { "job-uri", "job-id" })
                count = count + 1
            end
        end
        conn.response = response
    elseif op == IPP.OP_CANCEL_JOB then
        local job = self:findJob(requestedJobId(request) or -1)
        if not job then
            conn.response = newResponse(request, IPP.ERR_NOT_FOUND)
        elseif job.state == IPP.JOB_COMPLETED then
            conn.response = newResponse(request, IPP.ERR_NOT_POSSIBLE)
        else
            self:cancelJob(job)
            conn.response = newResponse(request, IPP.OK)
        end
    elseif op == IPP.OP_CANCEL_MY_JOBS then
        local user = tostring(IPP.getValue(request, "requesting-user-name", "anonymous"))
        for _, job in ipairs(self.jobs) do
            if job.user == user then
                self:cancelJob(job)
            end
        end
        conn.response = newResponse(request, IPP.OK)
    elseif op == IPP.OP_CLOSE_JOB then
        local job = self:findJob(requestedJobId(request) or -1)
        if not job then
            conn.response = newResponse(request, IPP.ERR_NOT_FOUND)
        else
            local response = newResponse(request, IPP.OK)
            self:addJobGroup(response, job, requested)
            conn.response = response
        end
    elseif op == IPP.OP_IDENTIFY_PRINTER then
        conn.response = newResponse(request, IPP.OK)
        if self.on_identify then
            pcall(self.on_identify)
        end
    else
        conn.response = newResponse(request, IPP.ERR_OPERATION_NOT_SUPPORTED)
    end
    return true
end

function Server:cancelJob(job)
    if job.state == IPP.JOB_COMPLETED or job.state == IPP.JOB_CANCELED then
        return
    end
    job.state = IPP.JOB_CANCELED
    job.state_reasons = { "job-canceled-by-user" }
    job.completed = self.clock()
    self.printer.queued_job_count = math.max(self.printer.queued_job_count - 1, 0)
end

--- Drops the oldest finished jobs, so the list does not grow forever.
function Server:pruneJobs(keep)
    keep = keep or 20
    while #self.jobs > keep do
        table.remove(self.jobs, 1)
    end
end

return Server
