--[[--
KOPrinter: the KOReader screen as an IPP printer.

Advertises an IPP printer whose page size is the screen itself, accepts PDF
print jobs from any computer or phone on the network, and opens what it
receives in KOReader.

The IPP server is polled from the UIManager main loop, like the mDNS
responder and the HTTP inspector plugin do with their sockets, so a job
transfer never blocks the UI. Discovery is delegated to the mDNS responder
plugin: only one responder can hold UDP port 5353, so this plugin declares
its service through the `MDNSCollectServices` event instead of running a
second one.

@module koplugin.KOPrinter
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Printer = require("ipp_printer")
local Server = require("ipp_server")

local SETTINGS_KEY = "koprinter"
local DEFAULT_PORT = 631
-- Ports below 1024 need root, which KOReader has on a Kindle but not on a
-- computer or on Android; the SRV record carries whatever port we get.
local FALLBACK_PORT = 8631
local SPOOL_SUBDIR = "KOPrinter"
local MAX_CONSECUTIVE_ERRORS = 10
-- Delays (seconds) of the start attempts after a resume, when no network
-- event tells us that the connection is back.
local RESUME_RETRY_DELAYS = { 2, 5, 15, 30 }

-- Everything below outlives plugin instances: KOReader instantiates plugins
-- again on every document load and on reader/file manager switches.
local settings = G_reader_settings:readSetting(SETTINGS_KEY, {})
local server
local printer
local zmq_adapter
local consecutive_errors = 0
local resume_retry = 0
local last_error

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Reads a screen property without assuming which KOReader version is
-- running: a missing accessor falls back to a sane value.
local function screenProperty(name, fallback)
    local screen = Device.screen
    if not screen or type(screen[name]) ~= "function" then
        return fallback
    end
    local ok, value = pcall(screen[name], screen)
    if not ok or type(value) ~= "number" or value <= 0 then
        return fallback
    end
    return value
end

local function hasColorScreen()
    for _, owner in ipairs({ Device, Device.screen }) do
        if owner and type(owner.hasColorScreen) == "function" then
            local ok, value = pcall(owner.hasColorScreen, owner)
            if ok then
                return value and true or false
            end
        end
        if owner and type(owner.isColorScreen) == "function" then
            local ok, value = pcall(owner.isColorScreen, owner)
            if ok then
                return value and true or false
            end
        end
    end
    return false
end

local function deviceModel()
    local model = Device.model
    if type(model) ~= "string" or model == "" then
        return "KOReader"
    end
    return model
end

local function defaultPrinterName()
    return T(_("KOReader on %1"), deviceModel())
end

local function printerName()
    local name = settings.printer_name
    if type(name) ~= "string" or name:gsub("%s", "") == "" then
        return defaultPrinterName()
    end
    return name
end

local function configuredPort()
    return tonumber(settings.port) or DEFAULT_PORT
end

--- Where received documents are written. Under the library directory, so
-- they show up where the user looks for books.
local function spoolDir()
    if type(settings.spool_dir) == "string" and settings.spool_dir ~= "" then
        return settings.spool_dir
    end
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir
    if type(home) ~= "string" or home == "" then
        home = "/tmp"
    end
    return home .. "/" .. SPOOL_SUBDIR
end

local function ensureSpoolDir()
    local path = spoolDir()
    if lfs.attributes(path, "mode") == "directory" then
        return path
    end
    -- Create the parents too: home_dir may itself be missing on a fresh install.
    local partial = path:sub(1, 1) == "/" and "" or "."
    for component in path:gmatch("[^/]+") do
        partial = partial .. "/" .. component
        if lfs.attributes(partial, "mode") ~= "directory" then
            lfs.mkdir(partial)
        end
    end
    if lfs.attributes(path, "mode") ~= "directory" then
        return nil, T(_("Cannot create %1"), path)
    end
    return path
end

local function networkInterface()
    return NetworkMgr:getNetworkInterfaceName() or "wlan0"
end

local function firewallRule(interface, port)
    return string.format("INPUT -i %s -p tcp --dport %d -j ACCEPT", interface, port)
end

--- Lets IPP through the Kindle firewall, whose INPUT policy drops by default.
local function openFirewall(interface, port)
    if not Device:isKindle() then
        return
    end
    local rule = firewallRule(interface, port)
    os.execute(string.format("iptables -C %s 2>/dev/null || iptables -I %s", rule, rule))
end

local function closeFirewall(interface, port)
    if not Device:isKindle() then
        return
    end
    os.execute(string.format("iptables -D %s 2>/dev/null", firewallRule(interface, port)))
end

local function saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, settings)
end

local plugin_logger = {
    dbg = function(m) logger.dbg(m) end,
    info = function(m) logger.info(m) end,
    warn = function(m) logger.warn(m) end,
    err = function(m) logger.err(m) end,
}

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

local KOPrinter = WidgetContainer:extend{
    name = "KOPrinter",
    is_doc_only = false,
}

function KOPrinter:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if KOPrinter.isEnabled() then
        -- Wait until every plugin is loaded: the mDNS responder may be starting.
        UIManager:nextTick(KOPrinter.startIfPossible)
    end
end

function KOPrinter.isEnabled()
    return settings.enabled ~= false
end

function KOPrinter.isRunning()
    return server ~= nil and server:isRunning()
end

function KOPrinter.opensOnReceive()
    return settings.open_on_receive ~= false
end

-------------------------------------------------------------------------------
-- Receiving a document
-------------------------------------------------------------------------------

--- Hands a received document to KOReader. Called from the socket poll, so
-- the actual work is deferred to the next tick: opening a document tears
-- down and rebuilds the UI, including this very plugin instance.
local function handleJob(job)
    UIManager:nextTick(function()
        if lfs.attributes(job.path, "mode") ~= "file" then
            logger.err("KOPrinter: received document vanished:", job.path)
            return
        end
        if not KOPrinter.opensOnReceive() then
            UIManager:show(InfoMessage:new{
                text = T(_("Document received:\n%1"), job.name),
                timeout = 3,
            })
            return
        end
        local ok, err = pcall(function()
            require("apps/reader/readerui"):showReader(job.path)
        end)
        if not ok then
            logger.err("KOPrinter: cannot open the received document:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("Received a document but cannot open it:\n%1"), job.path),
            })
        end
    end)
end

--- Answers Identify-Printer, which a client uses to make sure it is talking
-- to the device in front of the user.
local function identify()
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{
            text = T(_("This is %1"), printerName()),
            timeout = 5,
        })
    end)
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

--- Describes the screen as a printer. Width and height are taken in the
-- screen's upright orientation, so rotating the device does not change the
-- advertised page size.
local function buildPrinter(port)
    local width = screenProperty("getWidth", 600)
    local height = screenProperty("getHeight", 800)
    local dpi = screenProperty("getDPI", 160)
    return Printer.new{
        name = printerName(),
        model = deviceModel(),
        width_px = width,
        height_px = height,
        dpi = dpi,
        color = hasColorScreen(),
        port = port,
        host = Device.model and (Device.model:lower():gsub("[^%w-]", "-") .. ".local") or "localhost",
    }
end

--- Polled by UIManager on every iteration of its main loop.
local function poll()
    if not server then
        return nil
    end
    local ok, err = pcall(server.poll, server)
    if not ok then
        consecutive_errors = consecutive_errors + 1
        logger.err("KOPrinter: poll error:", err)
        if consecutive_errors >= MAX_CONSECUTIVE_ERRORS then
            logger.err("KOPrinter: too many errors, stopping the IPP server")
            KOPrinter.stop()
        end
        return nil
    end
    consecutive_errors = 0
    return nil
end

function KOPrinter.start()
    if KOPrinter.isRunning() then
        return true
    end
    local spool, spool_err = ensureSpoolDir()
    if not spool then
        last_error = spool_err
        logger.err("KOPrinter:", spool_err)
        return nil, spool_err
    end

    local interface = networkInterface()
    -- Fall back to an unprivileged port when the configured one cannot be
    -- bound: 631 needs root, which KOReader has on a Kindle but not on a
    -- computer or on Android, and it may also be taken by a local cupsd.
    -- Whichever port we end up on is the one the SRV record advertises.
    local candidates = { configuredPort() }
    if candidates[1] ~= FALLBACK_PORT then
        candidates[#candidates + 1] = FALLBACK_PORT
    end

    local err
    for _, port in ipairs(candidates) do
        printer = buildPrinter(port)
        server = Server.new{
            printer = printer,
            port = port,
            spool_dir = spool,
            logger = plugin_logger,
            on_job = handleJob,
            on_identify = identify,
        }
        openFirewall(interface, port)
        local ok
        ok, err = server:start()
        if ok then
            last_error = nil
            consecutive_errors = 0
            zmq_adapter = {
                waitEvent = poll,
                -- UIManager:quit() calls this on exit.
                stop = KOPrinter.stop,
            }
            UIManager:insertZMQ(zmq_adapter)
            -- Let the mDNS responder announce the printer right away.
            UIManager:broadcastEvent(Event:new("MDNSServicesChanged"))
            logger.info(string.format("KOPrinter: printing to %s on port %d, spooling into %s",
                printer.media_name, port, spool))
            return true
        end
        closeFirewall(interface, port)
        server = nil
        printer = nil
        logger.warn("KOPrinter:", err)
    end

    last_error = err
    return nil, err
end

function KOPrinter.stop()
    if zmq_adapter then
        UIManager:removeZMQ(zmq_adapter)
        zmq_adapter = nil
    end
    if server then
        local port = server.port
        server:stop()
        server = nil
        printer = nil
        closeFirewall(networkInterface(), port)
        -- Withdraw the Bonjour service instead of leaving a dead printer
        -- in the client's list.
        UIManager:broadcastEvent(Event:new("MDNSServicesChanged"))
    end
end

function KOPrinter.restart()
    KOPrinter.stop()
    return KOPrinter.start()
end

function KOPrinter.startIfPossible()
    if not KOPrinter.isEnabled() or KOPrinter.isRunning() then
        return
    end
    if not NetworkMgr:isConnected() then
        logger.dbg("KOPrinter: no network, not starting")
        return
    end
    KOPrinter.start()
end

--- Retries after a resume, when no network event announces the connection.
function KOPrinter.scheduleStart()
    resume_retry = 0
    local function attempt()
        resume_retry = resume_retry + 1
        KOPrinter.startIfPossible()
        if not KOPrinter.isRunning() and RESUME_RETRY_DELAYS[resume_retry + 1] then
            UIManager:scheduleIn(RESUME_RETRY_DELAYS[resume_retry + 1], attempt)
        end
    end
    UIManager:scheduleIn(RESUME_RETRY_DELAYS[1], attempt)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

--- The mDNS responder asks every plugin what to advertise. Answering with
-- nothing while the server is down withdraws the printer.
function KOPrinter:onMDNSCollectServices(services)
    if not KOPrinter.isRunning() then
        return
    end
    services[#services + 1] = {
        type = "_ipp._tcp",
        port = server.port,
        instance = printerName(),
        txt = printer:txtRecord(),
    }
end

function KOPrinter:onNetworkConnected()
    UIManager:nextTick(KOPrinter.startIfPossible)
end

function KOPrinter:onNetworkDisconnecting()
    KOPrinter.stop()
end

function KOPrinter:onNetworkDisconnected()
    KOPrinter.stop()
end

function KOPrinter:onSuspend()
    KOPrinter.stop()
end

function KOPrinter:onEnterStandby()
    KOPrinter.stop()
end

function KOPrinter:onResume()
    KOPrinter.scheduleStart()
end

function KOPrinter:onLeaveStandby()
    UIManager:nextTick(KOPrinter.startIfPossible)
end

function KOPrinter:onToggleKOPrinter()
    settings.enabled = not KOPrinter.isEnabled()
    saveSettings()
    if KOPrinter.isEnabled() then
        KOPrinter.startIfPossible()
    else
        KOPrinter.stop()
    end
    UIManager:show(InfoMessage:new{
        text = KOPrinter.isRunning() and T(_("Printer available: %1"), printerName())
            or _("Printer switched off"),
        timeout = 2,
    })
    return true
end

function KOPrinter:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_koprinter", {
        category = "none",
        event = "ToggleKOPrinter",
        title = _("Toggle KOPrinter"),
        general = true,
    })
end

-------------------------------------------------------------------------------
-- Menu
-------------------------------------------------------------------------------

function KOPrinter.statusText()
    if not KOPrinter.isEnabled() then
        return _("Off")
    end
    if not KOPrinter.isRunning() then
        return last_error and T(_("Not running: %1"), last_error) or _("Not running")
    end
    local w, h = printer:sizeMM()
    return T(_("Ready on port %1, page %2 x %3 mm"),
        server.port, string.format("%.0f", w), string.format("%.0f", h))
end

function KOPrinter.detailsText()
    local lines = {}
    local function add(label, value)
        lines[#lines + 1] = label .. ": " .. tostring(value)
    end
    add(_("Printer"), printerName())
    add(_("Spool folder"), spoolDir())
    if printer then
        local w, h = printer:sizeMM()
        add(_("Screen"), string.format("%d x %d px, %d dpi",
            printer.width_px, printer.height_px, printer.dpi))
        add(_("Page"), string.format("%.2f x %.2f mm", w, h))
        add(_("Colour"), printer.color and _("yes") or _("no"))
        add(_("Address"), printer:uri())
    end
    if server then
        local status = server:getStatus()
        add(_("Jobs received"), status.stats.jobs)
        add(_("Bytes received"), status.stats.bytes)
        add(_("Open connections"), status.connections)
        if status.stats.errors > 0 then
            add(_("Errors"), status.stats.errors)
        end
    end
    if last_error then
        add(_("Last error"), last_error)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("Documents arrive as PDF, laid out to the size of the screen.")
    if not KOPrinter.isRunning() then
        lines[#lines + 1] = _("The mDNS responder plugin must be enabled for the printer to be found.")
    end
    return table.concat(lines, "\n")
end

function KOPrinter:showPrinterNameDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Printer name"),
        description = _("The name shown in the printer list of your computer or phone."),
        input = printerName(),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialog)
                    settings.printer_name = name ~= "" and name or nil
                    saveSettings()
                    if KOPrinter.isRunning() then
                        KOPrinter.restart()
                    end
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KOPrinter:showPortDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("IPP port"),
        description = T(_("Standard IPP is %1. A port below 1024 needs root, and %2 is used when it cannot be bound."),
            DEFAULT_PORT, FALLBACK_PORT),
        input = tostring(configuredPort()),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local port = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if port and port >= 1 and port <= 65535 then
                        settings.port = port
                        saveSettings()
                        if KOPrinter.isRunning() then
                            KOPrinter.restart()
                        end
                    end
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KOPrinter:addToMainMenu(menu_items)
    menu_items.koprinter = {
        text = _("KOPrinter (IPP printer)"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Enable KOPrinter"),
                checked_func = KOPrinter.isEnabled,
                callback = function()
                    self:onToggleKOPrinter()
                end,
            },
            {
                text_func = KOPrinter.statusText,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = KOPrinter.detailsText() })
                end,
            },
            {
                text_func = function()
                    return T(_("Printer name: %1"), printerName())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showPrinterNameDialog(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Port: %1"), server and server.port or configuredPort())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showPortDialog(touchmenu_instance)
                end,
            },
            {
                text = _("Open received documents immediately"),
                help_text = _("When off, an incoming document is only announced, and stays in the spool folder."),
                checked_func = KOPrinter.opensOnReceive,
                callback = function()
                    settings.open_on_receive = not KOPrinter.opensOnReceive()
                    saveSettings()
                end,
            },
        },
    }
end

return KOPrinter
