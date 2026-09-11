-- End to end test of main.lua (the KOReader glue) with stubbed KOReader
-- modules but a real TCP socket: the plugin is started, a real IPP job is
-- printed to it and the document is followed all the way to KOReader.
-- Run with: luajit tests/test_main.lua
local plugin_dir = arg[0]:match("^(.*)/tests/[^/]*$") or (arg[0]:find("/") and "." or "..")
package.path = plugin_dir .. "/?.lua;" .. package.path
local home = os.getenv("HOME") or ""
package.path = home .. "/.luarocks/share/lua/5.1/?.lua;" .. package.path
package.cpath = home .. "/.luarocks/lib/lua/5.1/?.so;" .. package.cpath

local socket = require("socket")
local lfs = require("lfs")
local IPP = require("ipp_message")

local failures, checks = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end
local function noop() end

-- KOReader stubs ---------------------------------------------------------------
local spool_root = os.tmpname()
os.remove(spool_root)

local screen = {
    getWidth = function() return 1072 end,
    getHeight = function() return 1448 end,
    getDPI = function() return 300 end,
}
local device = {
    model = "KindleBasic4",
    home_dir = spool_root,
    screen = screen,
    isKindle = function() return false end,
    hasColorScreen = function() return false end,
}
local shown = {}
local scheduled = {}
local zmqs = {}
local executed = {}
local broadcast = {}
local opened = {}
local network = { connected = true, interface = "wlan0" }

package.preload["device"] = function() return device end
package.preload["dispatcher"] = function() return { registerAction = noop } end
package.preload["logger"] = function()
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)]) end))
    end }
end
package.preload["libs/libkoreader-lfs"] = function() return lfs end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) shown[#shown + 1] = o return o end }
end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, o)
        o.getInputText = function() return o.input end
        o.onShowKeyboard = noop
        return o
    end }
end
package.preload["ui/network/manager"] = function()
    return {
        isConnected = function() return network.connected end,
        getNetworkInterfaceName = function() return network.interface end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name, ...) return { handler = "on" .. name, args = { ... } } end }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn, ...) fn(...) end,
        scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
        insertZMQ = function(_, z) zmqs[#zmqs + 1] = z return z end,
        removeZMQ = function(_, z)
            for i = #zmqs, 1, -1 do if zmqs[i] == z then table.remove(zmqs, i) end end
        end,
        broadcastEvent = function(_, event) broadcast[#broadcast + 1] = event.handler end,
        show = function(_, w) shown[#shown + 1] = w end,
        close = noop,
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, class)
        class.new = function(cls, o)
            o = setmetatable(o or {}, { __index = cls })
            if o.init then o:init() end
            return o
        end
        return class
    end }
end
package.preload["apps/reader/readerui"] = function()
    return { showReader = function(_, path) opened[#opened + 1] = path end }
end
os.execute = function(cmd) executed[#executed + 1] = cmd return 0 end

local PORT = 18631
G_reader_settings = {
    store = { koprinter = { port = PORT } },
    readSetting = function(self, key, default)
        if self.store[key] == nil then self.store[key] = default end
        return self.store[key]
    end,
    saveSetting = function(self, key, value) self.store[key] = value end,
}

-- Load the plugin --------------------------------------------------------------
local KOPrinter = require("main")
local plugin = KOPrinter:new{ ui = { menu = { registerToMainMenu = noop } } }

check(KOPrinter.isEnabled(), "enabled by default")
check(KOPrinter.isRunning(), "started on init when the network is connected")
check(#zmqs == 1 and zmqs[1].waitEvent and zmqs[1].stop, "registered as a ZMQ")
check(KOPrinter.opensOnReceive(), "opens received documents by default")
check(lfs.attributes(spool_root .. "/KOPrinter", "mode") == "directory",
      "spool folder created under the library: " .. spool_root .. "/KOPrinter")
check(broadcast[#broadcast] == "onMDNSServicesChanged", "asked mDNS to announce the printer")

-- The mDNS responder collects the printer service ------------------------------
local services = {}
plugin:onMDNSCollectServices(services)
check(#services == 2 and services[1].type == "_ipp._tcp", "declares an _ipp._tcp service")
check(services[1].port == PORT, "declares the port it listens on: " .. tostring(services[1].port))
check(services[1].instance == "KOReader on KindleBasic4",
      "instance name from the device model: " .. tostring(services[1].instance))
check(services[1].subtypes and services[1].subtypes[1] == "_universal",
      "AirPrint subtype _universal is advertised")
check(services[2] and services[2].type == "_printer._tcp" and services[2].port == 0,
      "Bonjour requires _printer._tcp even when LPD is off")
local txt = table.concat(services[1].txt or {}, " ")
check(txt:find("pdl=application/pdf", 1, true), "TXT advertises PDF: " .. txt)
check(txt:find("image/urf", 1, true), "TXT lists image/urf so macOS treats it as AirPrint")
check(txt:find("rp=ipp/print", 1, true), "TXT carries the resource path")
check(txt:find("URF=", 1, true), "TXT carries a non-empty URF key")
check(not txt:find("printer-type=", 1, true),
      "TXT omits printer-type so CUPS does not treat it as a shared queue")

-- Drive the plugin the way UIManager does.
local function pump(times)
    for _ = 1, times or 1 do
        if zmqs[1] then zmqs[1].waitEvent(zmqs[1]) end
    end
end

--- Splits a raw response into the heads seen so far, the final (non-1xx)
-- head and the body. A 100 Continue arrives before the real answer, so it
-- cannot simply be treated as the response head.
local function split(response)
    local heads, rest = "", response
    while true do
        local head_end = rest:find("\r\n\r\n", 1, true)
        if not head_end then
            return heads .. rest, nil, ""
        end
        local head = rest:sub(1, head_end + 3)
        heads = heads .. head
        rest = rest:sub(head_end + 4)
        local status = head:match("^HTTP/%d%.%d%s+(%d%d%d)")
        if not status or status:sub(1, 1) ~= "1" then
            return heads, head, rest
        end
    end
end

--- Sends a raw HTTP request and reads the response, polling the server in
-- between since both live in this one thread. When `linger` is set, keeps
-- reading after the response is complete, so that a spurious second
-- response does not go unnoticed.
local function send(request_head, body_chunks, linger)
    local client = assert(socket.tcp())
    client:settimeout(2)
    assert(client:connect("127.0.0.1", PORT))
    assert(client:send(request_head))
    client:settimeout(0)
    for _, chunk in ipairs(body_chunks or {}) do
        pump(2)
        local sent, err = client:send(chunk)
        while not sent and err == "timeout" do
            pump(2)
            socket.sleep(0.002)
            sent, err = client:send(chunk)
        end
    end
    local response = ""
    for _ = 1, 400 do
        pump(2)
        local chunk, err, partial = client:receive(8192)
        response = response .. (chunk or partial or "")
        local _, final, body = split(response)
        if final then
            local len = tonumber(final:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
            if len and #body >= len then
                break
            end
        end
        if err == "closed" then
            break
        end
        socket.sleep(0.002)
    end
    if linger then
        for _ = 1, 20 do
            pump(2)
            local chunk, _, partial = client:receive(8192)
            response = response .. (chunk or partial or "")
            socket.sleep(0.002)
        end
    end
    client:close()
    local heads, _, body = split(response)
    local responses = select(2, response:gsub("HTTP/%d%.%d%s+%d%d%d", ""))
    return heads, body, responses
end

local function ippRequest(operation, attributes, data)
    return IPP.encode{
        version_major = 2, version_minor = 0,
        operation_id = operation, request_id = 1,
        groups = { { tag = IPP.TAG_OPERATION_ATTRIBUTES, attributes = attributes } },
        data = data,
    }
end

local function operationAttributes(extra)
    local attributes = {
        IPP.attr(IPP.TAG_CHARSET, "attributes-charset", "utf-8"),
        IPP.attr(IPP.TAG_NATURAL_LANGUAGE, "attributes-natural-language", "en"),
        IPP.attr(IPP.TAG_URI, "printer-uri", "ipp://127.0.0.1:" .. PORT .. "/ipp/print"),
    }
    for _, attr in ipairs(extra or {}) do
        attributes[#attributes + 1] = attr
    end
    return attributes
end

-- Get-Printer-Attributes describes the screen ----------------------------------
local body = ippRequest(IPP.OP_GET_PRINTER_ATTRIBUTES, operationAttributes{
    IPP.attr(IPP.TAG_KEYWORD, "requested-attributes", { "all", "media-col-database" }),
})
local head, payload = send(table.concat({
    "POST /ipp/print HTTP/1.1\r\n",
    "Host: 127.0.0.1:" .. PORT .. "\r\n",
    "Content-Type: application/ipp\r\n",
    "Content-Length: " .. #body .. "\r\n\r\n",
    body,
}))
check(head:find("200 OK", 1, true), "Get-Printer-Attributes answered 200: " .. head:sub(1, 40))
local response = IPP.decode(payload)
check(response and response.status_code == IPP.OK, "successful-ok")
check(IPP.getValue(response, "media-default") == "custom_koreader_90.76x122.6mm",
      "page size derived from the screen: " .. tostring(IPP.getValue(response, "media-default")))
local size = IPP.getValue(response, "media-size-supported")
check(size and size.members[1].values[1] == 9076 and size.members[2].values[1] == 12260,
      "media dimensions in hundredths of a millimetre")
-- CUPS names a zero-margin entry "<size>.Borderless" and the default
-- "<size>": both must exist or the default page size falls back to Letter.
local database = IPP.findAttribute(response, "media-col-database")
check(database and #database.values == 2, "media-col-database offers a bordered and a borderless entry")
local function margin(collection)
    for _, member in ipairs(collection.members) do
        if member.name == "media-top-margin" then return member.values[1] end
    end
end
check(database and margin(database.values[1]) > 0 and margin(database.values[2]) == 0,
      "default entry has a margin, second one is borderless")
local resolution = IPP.getValue(response, "printer-resolution-default")
check(resolution and resolution.x == 300, "resolution from the screen DPI")
check(IPP.getValue(response, "color-supported") == false, "monochrome screen reported as such")
check(IPP.getValue(response, "print-color-mode-supported") == "monochrome", "monochrome colour mode")
local formats = {}
for _, value in ipairs(IPP.getValues(response, "document-format-supported")) do
    formats[#formats + 1] = value
end
check(table.concat(formats, ",") == "application/pdf,application/octet-stream",
      "PDF only: " .. table.concat(formats, ","))

-- Print a real PDF the way macOS does: chunked, with Expect: 100-continue ------
local pdf = "%PDF-1.7\n" .. string.rep("koprinter payload ", 4096) .. "\n%%EOF\n"
local attributes = ippRequest(IPP.OP_PRINT_JOB, operationAttributes{
    IPP.attr(IPP.TAG_NAME, "requesting-user-name", "pierre"),
    IPP.attr(IPP.TAG_NAME, "job-name", "Reading list"),
    IPP.attr(IPP.TAG_MIME_MEDIA_TYPE, "document-format", "application/pdf"),
})
-- The IPP attributes and the document travel in one body, split across
-- several chunks so the streaming reader is actually exercised.
local whole = attributes .. pdf
local chunks = {}
local offset = 1
while offset <= #whole do
    local slice = whole:sub(offset, offset + 3000 - 1)
    chunks[#chunks + 1] = string.format("%x\r\n%s\r\n", #slice, slice)
    offset = offset + 3000
end
chunks[#chunks + 1] = "0\r\n\r\n"

head, payload = send(table.concat({
    "POST /ipp/print HTTP/1.1\r\n",
    "Host: 127.0.0.1:" .. PORT .. "\r\n",
    "Content-Type: application/ipp\r\n",
    "Transfer-Encoding: chunked\r\n",
    "Expect: 100-continue\r\n\r\n",
}), chunks)
check(head:find("100 Continue", 1, true), "answered the Expect: 100-continue")
check(head:find("200 OK", 1, true), "Print-Job answered 200")
local job_response = IPP.decode(payload)
check(job_response and job_response.status_code == IPP.OK,
      "Print-Job successful-ok: " .. tostring(job_response and job_response.status_code))
check(IPP.getValue(job_response, "job-state") == IPP.JOB_COMPLETED, "job reported as completed")

check(#opened == 1, "the received document was opened in KOReader: " .. #opened)
local received = opened[1]
check(received and received:find("Reading list", 1, true), "spooled under the job name: " .. tostring(received))
check(received and received:sub(-4) == ".pdf", "spooled with a .pdf extension")
local file = received and io.open(received, "rb")
local contents = file and file:read("*a")
if file then file:close() end
check(contents == pdf, string.format("document stored byte for byte (%d of %d bytes)",
      contents and #contents or -1, #pdf))

-- Without the option, a document is announced but not opened -------------------
G_reader_settings.store.koprinter.open_on_receive = false
opened = {}
shown = {}
head, payload = send(table.concat({
    "POST /ipp/print HTTP/1.1\r\n",
    "Host: 127.0.0.1:" .. PORT .. "\r\n",
    "Content-Type: application/ipp\r\n",
    "Content-Length: " .. #(attributes .. pdf) .. "\r\n\r\n",
    attributes .. pdf,
}))
check(head:find("200 OK", 1, true), "second job accepted with Content-Length framing")
check(#opened == 0, "document not opened when the option is off")
check(#shown > 0 and tostring(shown[#shown].text):find("Reading list", 1, true),
      "document announced instead: " .. tostring(shown[#shown] and shown[#shown].text))
G_reader_settings.store.koprinter.open_on_receive = true

-- A plain browser visiting the printer gets a status page ----------------------
local responses
head, payload, responses = send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", nil, true)
check(head:find("200 OK", 1, true), "GET / answers 200")
check(payload:find("1072 x 1448 px at 300 dpi", 1, true), "status page shows the screen")
check(responses == 1, "a non-IPP request gets exactly one response, got " .. responses)

-- A POST that is not IPP is refused, once, and the connection stays usable.
head, payload, responses = send(table.concat({
    "POST /ipp/print HTTP/1.1\r\nHost: 127.0.0.1\r\n",
    "Content-Type: text/plain\r\nContent-Length: 2\r\n\r\nhi",
}), nil, true)
check(head:find("415", 1, true), "a non-IPP content type is refused: " .. head:sub(1, 32))
check(responses == 1, "the refusal is sent once, got " .. responses)

-- Stopping withdraws the service ------------------------------------------------
KOPrinter.stop()
check(not KOPrinter.isRunning() and #zmqs == 0, "stopped")
services = {}
plugin:onMDNSCollectServices(services)
check(#services == 0, "nothing advertised once stopped")
check(broadcast[#broadcast] == "onMDNSServicesChanged", "asked mDNS to withdraw the printer")

-- Network and power events -------------------------------------------------------
plugin:onNetworkConnected()
check(KOPrinter.isRunning(), "restarted when the network comes back: " .. KOPrinter.statusText())
plugin:onSuspend()
check(not KOPrinter.isRunning(), "stopped on suspend")
plugin:onResume()
check(#scheduled >= 1 and scheduled[#scheduled].delay == 2, "resume schedules a retry")
network.connected = false
scheduled[#scheduled].fn()
check(not KOPrinter.isRunning() and scheduled[#scheduled].delay == 5, "retry chain continues while offline")
network.connected = true
scheduled[#scheduled].fn()
check(KOPrinter.isRunning(), "started once the network is back")

-- The Kindle firewall is opened for the IPP port and closed again -----------------
KOPrinter.stop()
device.isKindle = function() return true end
KOPrinter.start()
check(table.concat(executed, "\n"):find("iptables %-I INPUT %-p tcp %-%-dport " .. PORT),
      "firewall opened for the IPP port: " .. tostring(executed[#executed]))
zmqs[1].stop(zmqs[1]) -- what UIManager:quit() does
check(not KOPrinter.isRunning(), "stopped on quit")
check(table.concat(executed, "\n"):find("iptables %-D INPUT %-p tcp %-%-dport " .. PORT),
      "firewall closed on quit: " .. tostring(executed[#executed]))
device.isKindle = function() return false end

-- A busy port falls back to the unprivileged one -----------------------------------
local BUSY_PORT = 18632
local squatter = assert(socket.tcp4())
assert(squatter:setoption("reuseaddr", true))
assert(squatter:bind("0.0.0.0", BUSY_PORT))
assert(squatter:listen(1))
G_reader_settings.store.koprinter.port = BUSY_PORT
KOPrinter.start()
check(KOPrinter.isRunning(), "started despite the configured port being taken: " .. KOPrinter.statusText())
check(zmqs[1] ~= nil, "registered again after the fallback")
services = {}
plugin:onMDNSCollectServices(services)
check(services[1] and services[1].port == 8631,
      "advertises the port it actually got: " .. tostring(services[1] and services[1].port))
squatter:close()
KOPrinter.stop()

os.execute = nil
print(string.format("%s: %d checks, %d failures", arg[0], checks, failures))
os.exit(failures == 0 and 0 or 1)
