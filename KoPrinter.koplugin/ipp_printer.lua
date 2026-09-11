--[[--
Describes the KOReader screen as an IPP printer (RFC 8011, PWG 5100.14).

The printer advertises a single page size equal to the physical size of the
screen with no margins, so that a page laid out by the client is exactly one
screenful: a 1072x1448 screen at 300 dpi becomes a 90.76 x 122.60 mm sheet.

PDF is preferred. Apple Raster (`image/urf`) is accepted and decoded to
PDF so iOS AirPrint jobs can be opened; macOS still sends PDF.

The module takes a plain spec table rather than reaching into KOReader, so it
can be exercised without a device.

@module koplugin.KOPrinter.ipp_printer
--]]

local IPP = require("ipp_message")

local Printer = {}
Printer.__index = Printer

-- Page sizes are expressed in hundredths of a millimetre (RFC 8011 §5.2.11).
local HUNDREDTHS_MM_PER_INCH = 2540

-- A media entry whose four margins are zero is named "<size>.Borderless" by
-- the driverless PPD generator, while the default page size refers to
-- "<size>". Advertising only the zero-margin entry leaves the default
-- pointing at an option that does not exist, and the client silently falls
-- back to Letter. So the screen is offered twice: with a hairline margin,
-- which is the default, and borderless.
local DEFAULT_MARGIN = 100

local OPERATIONS = {
    IPP.OP_PRINT_JOB,
    IPP.OP_VALIDATE_JOB,
    IPP.OP_CREATE_JOB,
    IPP.OP_SEND_DOCUMENT,
    IPP.OP_CANCEL_JOB,
    IPP.OP_GET_JOB_ATTRIBUTES,
    IPP.OP_GET_JOBS,
    IPP.OP_GET_PRINTER_ATTRIBUTES,
    IPP.OP_CANCEL_MY_JOBS,
    IPP.OP_CLOSE_JOB,
    IPP.OP_IDENTIFY_PRINTER,
}

-- Attributes a client may send when creating a job. Anything else is
-- reported back in the unsupported-attributes group.
local JOB_CREATION_ATTRIBUTES = {
    "copies", "document-format", "document-name", "ipp-attribute-fidelity",
    "job-name", "media", "media-col", "multiple-document-handling",
    "orientation-requested", "output-bin", "print-color-mode", "print-quality",
    "print-scaling", "printer-resolution", "sides",
}

--- Rounds a pixel count to hundredths of a millimetre.
local function toHundredthsMM(pixels, dpi)
    return math.floor(pixels * HUNDREDTHS_MM_PER_INCH / dpi + 0.5)
end

--- Formats a hundredths-of-mm dimension the way PWG 5101.1 self-describing
-- names do: 9076 becomes "90.76", 12260 becomes "122.6".
local function formatDimension(hundredths)
    return (string.format("%.2f", hundredths / 100):gsub("0+$", ""):gsub("%.$", ""))
end

--- Encodes a Unix timestamp as an IPP dateTime (RFC 2579 DateAndTime).
local function encodeDateTime(timestamp)
    local t = os.date("*t", timestamp)
    local utc = os.date("!*t", timestamp)
    -- os.difftime on the two broken-down times gives the UTC offset.
    local offset = os.time(t) - os.time(utc)
    local sign = offset < 0 and "-" or "+"
    offset = math.abs(offset)
    return string.char(
        math.floor(t.year / 256), t.year % 256,
        t.month, t.day, t.hour, t.min, math.min(t.sec, 59), 0,
        sign:byte(), math.floor(offset / 3600), math.floor(offset % 3600 / 60))
end

--- Builds a stable UUID from a seed string (RFC 4122 version 4 layout, but
-- derived so that a device keeps the same printer identity across restarts).
local function uuidFromSeed(seed)
    local hash = 5381
    local bytes = {}
    for i = 1, 16 do
        for j = 1, #seed do
            hash = (hash * 33 + seed:byte(j) + i * 7) % 4294967296
        end
        bytes[i] = hash % 256
    end
    bytes[7] = 0x40 + bytes[7] % 16
    bytes[9] = 0x80 + bytes[9] % 64
    local hex = {}
    for i = 1, 16 do
        hex[i] = string.format("%02x", bytes[i])
    end
    return table.concat(hex, "", 1, 4) .. "-" .. table.concat(hex, "", 5, 6) .. "-"
        .. table.concat(hex, "", 7, 8) .. "-" .. table.concat(hex, "", 9, 10) .. "-"
        .. table.concat(hex, "", 11, 16)
end

Printer.uuidFromSeed = uuidFromSeed

--- Creates a printer description.
-- @tparam table spec
--   name: printer and DNS-SD instance name;
--   width_px, height_px, dpi: screen geometry, in its natural orientation;
--   color: true for a colour screen;
--   model: device model, used in printer-make-and-model;
--   port, resource: where the IPP server listens;
--   host: hostname or address clients use to reach it.
function Printer.new(spec)
    local self = setmetatable({}, Printer)
    self.name = spec.name or "KOReader"
    self.model = spec.model or "KOReader"
    self.dpi = math.max(math.floor(tonumber(spec.dpi) or 160), 1)
    self.color = spec.color and true or false
    self.port = tonumber(spec.port) or 631
    self.resource = spec.resource or "/ipp/print"
    self.host = spec.host or "localhost"
    self.location = spec.location or ""

    -- Portrait: the printer describes the screen in its natural orientation.
    local w = math.max(math.floor(tonumber(spec.width_px) or 600), 1)
    local h = math.max(math.floor(tonumber(spec.height_px) or 800), 1)
    self.width_px, self.height_px = math.min(w, h), math.max(w, h)

    self.media_width = toHundredthsMM(self.width_px, self.dpi)
    self.media_height = toHundredthsMM(self.height_px, self.dpi)
    self.media_name = string.format("custom_koreader_%sx%smm",
        formatDimension(self.media_width), formatDimension(self.media_height))
    -- iOS AirPrint will not send a job if the only size is a custom
    -- self-describing name. A4 and Letter are always advertised as well.
    self.media = {
        { name = self.media_name, width = self.media_width, height = self.media_height },
        { name = "iso_a4_210x297mm", width = 21000, height = 29700 },
        { name = "na_letter_8.5x11in", width = 21590, height = 27940 },
    }
    -- iOS lays jobs out on A4/Letter. Advertising only the screen size as
    -- default/ready makes AirPrint poll forever and never send Print-Job.
    self.default_media = self.media[2]

    self.uuid = spec.uuid or uuidFromSeed(self.model .. ":" .. self.name .. ":"
        .. self.width_px .. "x" .. self.height_px)
    self.start_time = spec.start_time or os.time()
    self.state = IPP.PRINTER_IDLE
    self.state_reasons = { "none" }
    self.accepting_jobs = true
    self.queued_job_count = 0
    return self
end

--- The URI clients are told to use.
function Printer:uri(scheme)
    return string.format("%s://%s:%d%s", scheme or "ipp", self.host, self.port, self.resource)
end

--- Screen size in millimetres, for the UI.
function Printer:sizeMM()
    return self.media_width / 100, self.media_height / 100
end

--- Seconds since the printer started, as required by printer-up-time.
function Printer:upTime(now)
    return math.max(math.floor((now or os.time()) - self.start_time), 1)
end

--- The media-size collection: just the two dimensions.
function Printer:mediaSizeCollection(media)
    media = media or self.media[1]
    return IPP.collection{
        IPP.attr(IPP.TAG_INTEGER, "x-dimension", media.width),
        IPP.attr(IPP.TAG_INTEGER, "y-dimension", media.height),
    }
end

--- The full media-col collection, for a given margin in hundredths of a
-- millimetre. The screen size is offered with a hairline margin (the
-- default) and borderless; A4 and Letter use the same hairline margin.
function Printer:mediaColCollection(margin, media)
    margin = margin or DEFAULT_MARGIN
    media = media or self.media[1]
    return IPP.collection{
        IPP.attr(IPP.TAG_BEG_COLLECTION, "media-size", self:mediaSizeCollection(media)),
        IPP.attr(IPP.TAG_KEYWORD, "media-size-name", media.name),
        IPP.attr(IPP.TAG_INTEGER, "media-bottom-margin", margin),
        IPP.attr(IPP.TAG_INTEGER, "media-left-margin", margin),
        IPP.attr(IPP.TAG_INTEGER, "media-right-margin", margin),
        IPP.attr(IPP.TAG_INTEGER, "media-top-margin", margin),
        IPP.attr(IPP.TAG_KEYWORD, "media-source", "auto"),
        IPP.attr(IPP.TAG_KEYWORD, "media-type", "stationery"),
        IPP.attr(IPP.TAG_KEYWORD, "media-color", "white"),
    }
end

function Printer:mediaNames()
    local names = {}
    for _, media in ipairs(self.media) do
        names[#names + 1] = media.name
    end
    return names
end

function Printer:mediaSizeCollections()
    local sizes = {}
    for _, media in ipairs(self.media) do
        sizes[#sizes + 1] = self:mediaSizeCollection(media)
    end
    return sizes
end

function Printer:mediaColDatabase()
    local cols = {
        self:mediaColCollection(DEFAULT_MARGIN, self.media[1]),
        self:mediaColCollection(0, self.media[1]),
    }
    for i = 2, #self.media do
        cols[#cols + 1] = self:mediaColCollection(DEFAULT_MARGIN, self.media[i])
    end
    return cols
end

--- iOS prints from the ready list and gets confused when one tray claims
-- several sizes, so only A4 is loaded.
function Printer:mediaColReady()
    return { self:mediaColCollection(DEFAULT_MARGIN, self.default_media) }
end

-------------------------------------------------------------------------------
-- Attribute set
-------------------------------------------------------------------------------

--- Every printer attribute, tagged with the group it belongs to so that
-- `requested-attributes` can select a subset.
-- @treturn table list of { group = "printer-description"|"job-template", attr = <attribute> }
function Printer:attributes(now)
    local color_modes = self.color and { "auto", "color", "monochrome" } or { "auto", "monochrome" }
    local out = {}
    local function add(group, attr)
        out[#out + 1] = { group = group, attr = attr }
    end
    local function description(...)
        add("printer-description", IPP.attr(...))
    end
    local function template(...)
        add("job-template", IPP.attr(...))
    end

    -- Identification and addressing.
    description(IPP.TAG_URI, "printer-uri-supported", self:uri("ipp"))
    description(IPP.TAG_KEYWORD, "uri-security-supported", "none")
    description(IPP.TAG_KEYWORD, "uri-authentication-supported", "none")
    description(IPP.TAG_NAME, "printer-name", self.name)
    description(IPP.TAG_NAME, "printer-dns-sd-name", self.name)
    description(IPP.TAG_TEXT, "printer-info", self.name)
    description(IPP.TAG_TEXT, "printer-location", self.location)
    description(IPP.TAG_TEXT, "printer-make-and-model", "KOReader " .. self.model)
    description(IPP.TAG_URI, "printer-uuid", "urn:uuid:" .. self.uuid)
    description(IPP.TAG_TEXT, "printer-device-id",
        string.format("MFG:KOReader;MDL:%s;CMD:PDF,URF,JPEG;DES:KOReader screen;", self.model))
    description(IPP.TAG_URI, "printer-more-info",
        string.format("http://%s:%d/", self.host, self.port))
    description(IPP.TAG_TEXT, "mopria-certified", "1.3")
    description(IPP.TAG_KEYWORD, "printer-kind", "document")

    -- State.
    description(IPP.TAG_ENUM, "printer-state", self.state)
    description(IPP.TAG_KEYWORD, "printer-state-reasons", self.state_reasons)
    description(IPP.TAG_TEXT, "printer-state-message",
        self.accepting_jobs and "Ready to print to the screen" or "Not accepting jobs")
    description(IPP.TAG_BOOLEAN, "printer-is-accepting-jobs", self.accepting_jobs)
    description(IPP.TAG_INTEGER, "queued-job-count", self.queued_job_count)
    description(IPP.TAG_INTEGER, "printer-up-time", self:upTime(now))
    description(IPP.TAG_DATE_TIME, "printer-current-time", encodeDateTime(now or os.time()))
    description(IPP.TAG_INTEGER, "pages-per-minute", 10)

    -- Protocol capabilities.
    description(IPP.TAG_CHARSET, "charset-configured", "utf-8")
    description(IPP.TAG_CHARSET, "charset-supported", "utf-8")
    description(IPP.TAG_NATURAL_LANGUAGE, "natural-language-configured", "en")
    description(IPP.TAG_NATURAL_LANGUAGE, "generated-natural-language-supported", "en")
    description(IPP.TAG_KEYWORD, "ipp-versions-supported", { "1.1", "2.0" })
    description(IPP.TAG_KEYWORD, "ipp-features-supported", "ipp-everywhere")
    description(IPP.TAG_ENUM, "operations-supported", OPERATIONS)
    description(IPP.TAG_BOOLEAN, "multiple-document-jobs-supported", false)
    description(IPP.TAG_INTEGER, "multiple-operation-time-out", 60)
    description(IPP.TAG_KEYWORD, "multiple-operation-time-out-action", "process-job")
    description(IPP.TAG_KEYWORD, "pdl-override-supported", "attempted")
    description(IPP.TAG_KEYWORD, "compression-supported", "none")
    description(IPP.TAG_KEYWORD, "job-creation-attributes-supported", JOB_CREATION_ATTRIBUTES)
    description(IPP.TAG_KEYWORD, "printer-get-attributes-supported", "document-format")
    description(IPP.TAG_KEYWORD, "which-jobs-supported", { "completed", "not-completed", "all" })
    description(IPP.TAG_KEYWORD, "identify-actions-default", "display")
    description(IPP.TAG_KEYWORD, "identify-actions-supported", "display")
    -- One tray named `auto`, loaded with A4. A dummy empty `auto` tray plus
    -- several ready sizes on that source makes iOS poll forever.
    description(IPP.TAG_OCTET_STRING, "printer-input-tray", string.format(
        "type=sheetFeedAutoNonRemovableTray;mediafeed=%d;mediaxfeed=%d;"
        .. "maxcapacity=1;level=-3;status=0;name=auto;",
        self.default_media.height, self.default_media.width))
    description(IPP.TAG_OCTET_STRING, "printer-output-tray",
        "type=unRemovableBin;maxcapacity=1;remaining=-3;status=0;"
        .. "name=face-up;stackingorder=firstToLast;pagedelivery=faceUp;")
    description(IPP.TAG_BEG_COLLECTION, "finishings-col-database",
        IPP.collection{ IPP.attr(IPP.TAG_KEYWORD, "finishing-template", "none") })
    description(IPP.TAG_BEG_COLLECTION, "finishings-col-ready",
        IPP.collection{ IPP.attr(IPP.TAG_KEYWORD, "finishing-template", "none") })
    description(IPP.TAG_KEYWORD, "finishings-col-supported", "finishing-template")
    description(IPP.TAG_KEYWORD, "finishing-template-supported", "none")
    -- iOS asks for these on every status poll. Omitting them looks like
    -- "unknown" rather than "none", and the print sheet never submits.
    description(IPP.TAG_NO_VALUE, "printer-mandatory-job-attributes")
    description(IPP.TAG_NO_VALUE, "job-presets-supported")
    description(IPP.TAG_URI, "printer-supply-info-uri",
        string.format("http://%s:%d/", self.host, self.port))
    description(IPP.TAG_BOOLEAN, "job-account-id-supported", false)
    description(IPP.TAG_INTEGER, "document-password-supported", 0)
    description(IPP.TAG_BOOLEAN, "landscape-orientation-requested-preferred", false)
    description(IPP.TAG_KEYWORD, "jpeg-features-supported", "none")
    description(IPP.TAG_RANGE_OF_INTEGER, "pdf-k-octets-supported", IPP.range(0, 102400))
    description(IPP.TAG_RANGE_OF_INTEGER, "jpeg-k-octets-supported", IPP.range(0, 65536))
    description(IPP.TAG_RANGE_OF_INTEGER, "jpeg-x-dimension-supported", IPP.range(0, 16384))
    description(IPP.TAG_RANGE_OF_INTEGER, "jpeg-y-dimension-supported", IPP.range(0, 16384))

    -- PDF from macOS/CUPS; Apple Raster from iOS AirPrint (decoded to PDF).
    description(IPP.TAG_MIME_MEDIA_TYPE, "document-format-default", "application/pdf")
    description(IPP.TAG_MIME_MEDIA_TYPE, "document-format-preferred", "application/pdf")
    description(IPP.TAG_MIME_MEDIA_TYPE, "document-format-supported",
        { "application/pdf", "application/octet-stream", "image/urf", "image/jpeg" })
    description(IPP.TAG_KEYWORD, "pdf-versions-supported",
        { "adobe-1.4", "adobe-1.5", "adobe-1.6", "adobe-1.7", "iso-32000-1_2008" })
    description(IPP.TAG_BOOLEAN, "color-supported", self.color)
    description(IPP.TAG_KEYWORD, "urf-supported", self:urfFeatures())

    -- A4 is the default so iOS will actually create a job. The screen size
    -- stays in media-supported for macOS clients that pick it explicitly.
    template(IPP.TAG_KEYWORD, "media-default", self.default_media.name)
    template(IPP.TAG_KEYWORD, "media-supported", self:mediaNames())
    template(IPP.TAG_KEYWORD, "media-ready", self.default_media.name)
    template(IPP.TAG_BEG_COLLECTION, "media-size-supported", self:mediaSizeCollections())
    template(IPP.TAG_BEG_COLLECTION, "media-col-default",
        self:mediaColCollection(DEFAULT_MARGIN, self.default_media))
    template(IPP.TAG_BEG_COLLECTION, "media-col-database", self:mediaColDatabase())
    template(IPP.TAG_BEG_COLLECTION, "media-col-ready", self:mediaColReady())
    template(IPP.TAG_KEYWORD, "media-col-supported", {
        "media-bottom-margin", "media-left-margin", "media-right-margin",
        "media-size", "media-size-name", "media-source", "media-top-margin",
        "media-type", "media-color",
    })
    template(IPP.TAG_INTEGER, "media-bottom-margin-supported", { 0, DEFAULT_MARGIN })
    template(IPP.TAG_INTEGER, "media-left-margin-supported", { 0, DEFAULT_MARGIN })
    template(IPP.TAG_INTEGER, "media-right-margin-supported", { 0, DEFAULT_MARGIN })
    template(IPP.TAG_INTEGER, "media-top-margin-supported", { 0, DEFAULT_MARGIN })
    template(IPP.TAG_KEYWORD, "media-source-supported", "auto")
    template(IPP.TAG_KEYWORD, "media-type-supported", "stationery")

    -- Everything else the screen can or cannot do.
    template(IPP.TAG_RESOLUTION, "printer-resolution-default", IPP.resolution(self.dpi, self.dpi))
    template(IPP.TAG_RESOLUTION, "printer-resolution-supported", IPP.resolution(self.dpi, self.dpi))
    template(IPP.TAG_KEYWORD, "print-color-mode-default", self.color and "auto" or "monochrome")
    template(IPP.TAG_KEYWORD, "print-color-mode-supported", color_modes)
    template(IPP.TAG_ENUM, "print-quality-default", 4)
    template(IPP.TAG_ENUM, "print-quality-supported", { 3, 4, 5 })
    template(IPP.TAG_KEYWORD, "print-scaling-default", "auto")
    template(IPP.TAG_KEYWORD, "print-scaling-supported", { "auto", "auto-fit", "fill", "fit", "none" })
    template(IPP.TAG_KEYWORD, "sides-default", "one-sided")
    template(IPP.TAG_KEYWORD, "sides-supported", "one-sided")
    template(IPP.TAG_INTEGER, "copies-default", 1)
    template(IPP.TAG_RANGE_OF_INTEGER, "copies-supported", IPP.range(1, 99))
    template(IPP.TAG_ENUM, "orientation-requested-default", 3)
    template(IPP.TAG_ENUM, "orientation-requested-supported", { 3, 4, 5, 6 })
    template(IPP.TAG_ENUM, "finishings-default", 3)
    template(IPP.TAG_ENUM, "finishings-supported", 3)
    template(IPP.TAG_KEYWORD, "job-sheets-default", "none")
    template(IPP.TAG_KEYWORD, "job-sheets-supported", "none")
    template(IPP.TAG_INTEGER, "number-up-default", 1)
    template(IPP.TAG_INTEGER, "number-up-supported", 1)
    template(IPP.TAG_KEYWORD, "output-bin-default", "face-up")
    template(IPP.TAG_KEYWORD, "output-bin-supported", "face-up")
    template(IPP.TAG_INTEGER, "job-priority-default", 50)
    template(IPP.TAG_INTEGER, "job-priority-supported", 100)
    template(IPP.TAG_KEYWORD, "multiple-document-handling-default", "separate-documents-collated-copies")
    template(IPP.TAG_KEYWORD, "multiple-document-handling-supported",
        { "separate-documents-collated-copies", "separate-documents-uncollated-copies" })

    return out
end

--- Picks the attributes a client asked for.
-- @tparam table requested list of `requested-attributes` values, possibly nil
-- @treturn table list of attributes, in declaration order
function Printer:selectAttributes(requested, now)
    local all = self:attributes(now)
    if not requested or #requested == 0 then
        requested = { "all" }
    end

    local wanted_groups, wanted_names, want_all = {}, {}, false
    for _, name in ipairs(requested) do
        if name == "all" then
            want_all = true
        elseif name == "printer-description" or name == "job-template" then
            wanted_groups[name] = true
        else
            wanted_names[name] = true
        end
    end

    local selected = {}
    for _, entry in ipairs(all) do
        if want_all or wanted_groups[entry.group] or wanted_names[entry.attr.name] then
            selected[#selected + 1] = entry.attr
        end
    end
    return selected
end

--- Apple Raster features advertised in Bonjour `URF=` and IPP `urf-supported`.
function Printer:urfFeatures()
    local parts = { "V1.4" }
    if self.color then
        parts[#parts + 1] = "SRGB24"
    end
    parts[#parts + 1] = "W8"
    parts[#parts + 1] = "RS" .. tostring(self.dpi)
    parts[#parts + 1] = "DM1"
    parts[#parts + 1] = "IS1"
    parts[#parts + 1] = "PQ3-4-5"
    return parts
end

--- The Bonjour TXT record for `_ipp._tcp`.
--
-- AirPrint (and the macOS "Add Printer" dialog) only auto-selects a driver
-- for printers that advertise the `_universal` subtype and a non-empty URF
-- key. `pdl` lists `image/urf` as well as PDF. macOS still prefers PDF;
-- iOS sends URF, which is decoded to a PDF before KOReader opens it.
--
-- Do not advertise `printer-type`: CUPS treats that key as a shared CUPS
-- queue and builds a `dnssd://…/cups` URI, which makes macOS ask for a
-- driver instead of using AirPrint.
function Printer:txtRecord()
    return {
        "txtvers=1",
        "qtotal=1",
        "rp=" .. self.resource:gsub("^/", ""),
        "ty=" .. self.name,
        "product=(KOReader " .. self.model .. ")",
        "note=" .. self.location,
        "priority=0",
        "adminurl=http://" .. self.host .. ":" .. self.port .. "/",
        "pdl=application/pdf,image/urf",
        "URF=" .. table.concat(self:urfFeatures(), ","),
        "Color=" .. (self.color and "T" or "F"),
        "Duplex=F",
        "Copies=T",
        "Collate=F",
        "Sort=F",
        "Bind=F",
        "Staple=F",
        "Punch=F",
        "PaperMax=legal-A4",
        "kind=document",
        "UUID=" .. self.uuid,
        "mopria-certified=1.3",
    }
end

return Printer
