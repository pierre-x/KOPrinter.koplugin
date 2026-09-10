--[[--
Runs the IPP printer outside KOReader, for testing against a real client.

    luajit tools/standalone.lua [port] [spool_dir] [width] [height] [dpi]

Defaults describe a Kindle Basic 4 screen and spool into /tmp/koprinter.
Port 631 needs root on most systems, and is taken by cupsd on macOS, so pick
something like 8631 when testing on a computer.

Announce it over Bonjour from another terminal, then add it as a printer:

    dns-sd -P KOReader _ipp._tcp local 8631 $(hostname) 127.0.0.1 \
        txtvers=1 qtotal=1 rp=ipp/print pdl=application/pdf \
        ty=KOReader Color=F Duplex=F
--]]

local here = arg[0]:match("^(.*)/tools/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
-- LuaRocks puts LuaSocket outside LuaJIT's default path.
local home = os.getenv("HOME") or ""
package.path = home .. "/.luarocks/share/lua/5.1/?.lua;" .. package.path
package.cpath = home .. "/.luarocks/lib/lua/5.1/?.so;" .. package.cpath

local socket = require("socket")
local Printer = require("ipp_printer")
local Server = require("ipp_server")

-- Keep the log readable when stdout is a file.
io.stdout:setvbuf("line")

local port = tonumber(arg[1]) or 8631
local spool_dir = arg[2] or "/tmp/koprinter"
local width = tonumber(arg[3]) or 1072
local height = tonumber(arg[4]) or 1448
local dpi = tonumber(arg[5]) or 300

os.execute("mkdir -p '" .. spool_dir .. "'")

local function stamp()
    return os.date("%H:%M:%S")
end

local logger = {
    dbg = function(m) print(stamp() .. " [dbg] " .. m) end,
    info = function(m) print(stamp() .. " [info] " .. m) end,
    warn = function(m) print(stamp() .. " [warn] " .. m) end,
    err = function(m) print(stamp() .. " [err ] " .. m) end,
}

local printer = Printer.new{
    name = "KOReader",
    model = "KindleBasic4",
    width_px = width, height_px = height, dpi = dpi,
    color = false,
    port = port,
    host = "127.0.0.1",
}

local w, h = printer:sizeMM()
print(string.format("Screen  %d x %d px at %d dpi", printer.width_px, printer.height_px, printer.dpi))
print(string.format("Page    %.2f x %.2f mm  (%s)", w, h, printer.media_name))
print(string.format("URI     %s", printer:uri()))
print(string.format("Spool   %s", spool_dir))
print("")

--- The Bonjour announcement the mDNS plugin makes on a device, as a command
-- to run here: on a computer the system responder already owns port 5353.
local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local advertise = {
    "dns-sd -P", shellQuote(printer.name), "_ipp._tcp local",
    tostring(port), "localhost 127.0.0.1",
}
for _, entry in ipairs(printer:txtRecord()) do
    advertise[#advertise + 1] = shellQuote(entry)
end
print("Announce it on this machine with:")
print("  " .. table.concat(advertise, " "))
print("")

local server = Server.new{
    printer = printer,
    port = port,
    spool_dir = spool_dir,
    logger = logger,
    socket = socket,
    clock = os.time,
    on_job = function(job)
        print(string.format("%s ==> JOB %d  %q from %s  %d bytes  -> %s",
            stamp(), job.id, job.name, job.user, job.size, job.path))
        local file = io.open(job.path, "rb")
        if file then
            local head = file:read(8) or ""
            file:close()
            print(string.format("       magic %q  %s", head,
                head:sub(1, 4) == "%PDF" and "looks like a PDF" or "NOT a PDF"))
        end
    end,
}

local ok, err = server:start()
if not ok then
    io.stderr:write("cannot start: " .. tostring(err) .. "\n")
    os.exit(1)
end

print("serving, Ctrl-C to stop")
while true do
    server:poll()
    socket.sleep(0.02)
end
