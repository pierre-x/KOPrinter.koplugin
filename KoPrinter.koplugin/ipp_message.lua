--[[--
IPP binary encoder/decoder (RFC 8010).

An IPP message is a small binary header followed by attribute groups and,
for print operations, the document itself. Groups keep their order, because
IPP identifies an attribute by its group as much as by its name.

Attributes are represented as:

    { name = "media-supported", tag = M.TAG_KEYWORD, values = { "iso_a4", ... } }

and collection values (RFC 8010 §3.1.6) as:

    { members = { <attribute>, ... } }

so that a decoded message re-encodes to the same bytes.

@module koplugin.KoPrinter.ipp_message
--]]

local bit = require("bit")
local band, rshift = bit.band, bit.rshift

local M = {}

-------------------------------------------------------------------------------
-- Tags (RFC 8010 §3.5)
-------------------------------------------------------------------------------

M.TAG_OPERATION_ATTRIBUTES = 0x01
M.TAG_JOB_ATTRIBUTES = 0x02
M.TAG_END_OF_ATTRIBUTES = 0x03
M.TAG_PRINTER_ATTRIBUTES = 0x04
M.TAG_UNSUPPORTED_ATTRIBUTES = 0x05

M.TAG_UNSUPPORTED_VALUE = 0x10
M.TAG_UNKNOWN = 0x12
M.TAG_NO_VALUE = 0x13
M.TAG_INTEGER = 0x21
M.TAG_BOOLEAN = 0x22
M.TAG_ENUM = 0x23
M.TAG_OCTET_STRING = 0x30
M.TAG_DATE_TIME = 0x31
M.TAG_RESOLUTION = 0x32
M.TAG_RANGE_OF_INTEGER = 0x33
M.TAG_BEG_COLLECTION = 0x34
M.TAG_TEXT_WITH_LANGUAGE = 0x35
M.TAG_NAME_WITH_LANGUAGE = 0x36
M.TAG_END_COLLECTION = 0x37
M.TAG_TEXT = 0x41
M.TAG_NAME = 0x42
M.TAG_KEYWORD = 0x44
M.TAG_URI = 0x45
M.TAG_URI_SCHEME = 0x46
M.TAG_CHARSET = 0x47
M.TAG_NATURAL_LANGUAGE = 0x48
M.TAG_MIME_MEDIA_TYPE = 0x49
M.TAG_MEMBER_ATTR_NAME = 0x4A

-- Resolution units.
M.RESOLUTION_DPI = 3
M.RESOLUTION_DPCM = 4

-------------------------------------------------------------------------------
-- Operations and status codes
-------------------------------------------------------------------------------

M.OP_PRINT_JOB = 0x0002
M.OP_PRINT_URI = 0x0003
M.OP_VALIDATE_JOB = 0x0004
M.OP_CREATE_JOB = 0x0005
M.OP_SEND_DOCUMENT = 0x0006
M.OP_SEND_URI = 0x0007
M.OP_CANCEL_JOB = 0x0008
M.OP_GET_JOB_ATTRIBUTES = 0x0009
M.OP_GET_JOBS = 0x000A
M.OP_GET_PRINTER_ATTRIBUTES = 0x000B
M.OP_PAUSE_PRINTER = 0x0010
M.OP_RESUME_PRINTER = 0x0011
M.OP_PURGE_JOBS = 0x0012
M.OP_CLOSE_JOB = 0x003B
M.OP_IDENTIFY_PRINTER = 0x003C
M.OP_CANCEL_MY_JOBS = 0x0039
M.OP_GET_USER_PRINTER_ATTRIBUTES = 0x003E

M.OK = 0x0000
M.OK_IGNORED_OR_SUBSTITUTED = 0x0001
M.OK_CONFLICTING = 0x0002
M.ERR_BAD_REQUEST = 0x0400
M.ERR_FORBIDDEN = 0x0401
M.ERR_NOT_AUTHENTICATED = 0x0402
M.ERR_NOT_AUTHORIZED = 0x0403
M.ERR_NOT_POSSIBLE = 0x0404
M.ERR_TIMEOUT = 0x0405
M.ERR_NOT_FOUND = 0x0406
M.ERR_GONE = 0x0407
M.ERR_REQUEST_ENTITY_TOO_LARGE = 0x0408
M.ERR_REQUEST_VALUE_TOO_LONG = 0x0409
M.ERR_DOCUMENT_FORMAT_NOT_SUPPORTED = 0x040A
M.ERR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED = 0x040B
M.ERR_CHARSET_NOT_SUPPORTED = 0x040D
M.ERR_CONFLICTING_ATTRIBUTES = 0x040E
M.ERR_INTERNAL = 0x0500
M.ERR_OPERATION_NOT_SUPPORTED = 0x0501
M.ERR_SERVICE_UNAVAILABLE = 0x0502
M.ERR_VERSION_NOT_SUPPORTED = 0x0503
M.ERR_DEVICE_ERROR = 0x0504
M.ERR_TEMPORARY_ERROR = 0x0505
M.ERR_NOT_ACCEPTING_JOBS = 0x0506
M.ERR_BUSY = 0x0507
M.ERR_JOB_CANCELED = 0x0508

-- Job states (RFC 8011 §5.3.7).
M.JOB_PENDING = 3
M.JOB_HELD = 4
M.JOB_PROCESSING = 5
M.JOB_STOPPED = 6
M.JOB_CANCELED = 7
M.JOB_ABORTED = 8
M.JOB_COMPLETED = 9

-- Printer states (RFC 8011 §5.4.11).
M.PRINTER_IDLE = 3
M.PRINTER_PROCESSING = 4
M.PRINTER_STOPPED = 5

local OPERATION_NAMES = {
    [M.OP_PRINT_JOB] = "Print-Job",
    [M.OP_PRINT_URI] = "Print-URI",
    [M.OP_VALIDATE_JOB] = "Validate-Job",
    [M.OP_CREATE_JOB] = "Create-Job",
    [M.OP_SEND_DOCUMENT] = "Send-Document",
    [M.OP_SEND_URI] = "Send-URI",
    [M.OP_CANCEL_JOB] = "Cancel-Job",
    [M.OP_GET_JOB_ATTRIBUTES] = "Get-Job-Attributes",
    [M.OP_GET_JOBS] = "Get-Jobs",
    [M.OP_GET_PRINTER_ATTRIBUTES] = "Get-Printer-Attributes",
    [M.OP_PAUSE_PRINTER] = "Pause-Printer",
    [M.OP_RESUME_PRINTER] = "Resume-Printer",
    [M.OP_PURGE_JOBS] = "Purge-Jobs",
    [M.OP_CLOSE_JOB] = "Close-Job",
    [M.OP_IDENTIFY_PRINTER] = "Identify-Printer",
    [M.OP_CANCEL_MY_JOBS] = "Cancel-My-Jobs",
    [M.OP_GET_USER_PRINTER_ATTRIBUTES] = "Get-User-Printer-Attributes",
}

--- Human readable operation name, for logs.
function M.operationName(op)
    return OPERATION_NAMES[op] or string.format("0x%04X", op or 0)
end

-- Tags whose value is a plain string on the wire.
local STRING_TAGS = {
    [M.TAG_OCTET_STRING] = true,
    [M.TAG_TEXT] = true,
    [M.TAG_NAME] = true,
    [M.TAG_KEYWORD] = true,
    [M.TAG_URI] = true,
    [M.TAG_URI_SCHEME] = true,
    [M.TAG_CHARSET] = true,
    [M.TAG_NATURAL_LANGUAGE] = true,
    [M.TAG_MIME_MEDIA_TYPE] = true,
    [M.TAG_MEMBER_ATTR_NAME] = true,
}

-- Tags that carry no value at all.
local EMPTY_TAGS = {
    [M.TAG_UNSUPPORTED_VALUE] = true,
    [M.TAG_UNKNOWN] = true,
    [M.TAG_NO_VALUE] = true,
    [M.TAG_END_COLLECTION] = true,
}

--- True for the group delimiters, which have no name and no value.
function M.isDelimiter(tag)
    return tag >= 0x00 and tag <= 0x0F
end

-------------------------------------------------------------------------------
-- Attribute constructors
-------------------------------------------------------------------------------

--- Builds an attribute from a tag, a name and one or more values.
function M.attr(tag, name, ...)
    local values = { ... }
    -- A single table argument is either a list of values or a collection.
    if #values == 1 and type(values[1]) == "table" and values[1].members == nil
        and values[1].lower == nil and values[1].x == nil and values[1].text == nil then
        values = values[1]
    end
    return { tag = tag, name = name, values = values }
end

--- Resolution value, in dots per inch unless told otherwise.
function M.resolution(x, y, units)
    return { x = x, y = y or x, units = units or M.RESOLUTION_DPI }
end

--- rangeOfInteger value.
function M.range(lower, upper)
    return { lower = lower, upper = upper }
end

--- Collection value, from a list of attributes.
function M.collection(members)
    return { members = members }
end

--- textWithLanguage / nameWithLanguage value.
function M.withLanguage(language, text)
    return { language = language, text = text }
end

-------------------------------------------------------------------------------
-- Writer
-------------------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

function M.newWriter()
    return setmetatable({ chunks = {}, size = 0 }, Writer)
end

function Writer:raw(s)
    self.chunks[#self.chunks + 1] = s
    self.size = self.size + #s
end

function Writer:u8(n)
    self:raw(string.char(band(n, 0xFF)))
end

function Writer:u16(n)
    self:raw(string.char(band(rshift(n, 8), 0xFF), band(n, 0xFF)))
end

function Writer:i32(n)
    n = math.floor(n)
    if n < 0 then
        n = n + 4294967296
    end
    self:raw(string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
                         math.floor(n / 256) % 256, n % 256))
end

--- A length-prefixed string, as used for names and most values.
function Writer:str(s)
    s = s or ""
    if #s > 32767 then
        error("IPP string too long: " .. #s .. " bytes")
    end
    self:u16(#s)
    self:raw(s)
end

function Writer:build()
    return table.concat(self.chunks)
end

-------------------------------------------------------------------------------
-- Reader
-------------------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

function M.newReader(data, pos)
    return setmetatable({ data = data, pos = pos or 1 }, Reader)
end

function Reader:remaining()
    return #self.data - self.pos + 1
end

function Reader:raw(n)
    if self:remaining() < n then
        error("truncated IPP message")
    end
    local s = self.data:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return s
end

function Reader:u8()
    return self:raw(1):byte()
end

function Reader:u16()
    local a, b = self:raw(2):byte(1, 2)
    return a * 256 + b
end

function Reader:i32()
    local a, b, c, d = self:raw(4):byte(1, 4)
    local n = ((a * 256 + b) * 256 + c) * 256 + d
    if n >= 2147483648 then
        n = n - 4294967296
    end
    return n
end

function Reader:str()
    return self:raw(self:u16())
end

-------------------------------------------------------------------------------
-- Value encoding
-------------------------------------------------------------------------------

local encodeAttribute

local function encodeValue(w, tag, value)
    if EMPTY_TAGS[tag] then
        w:u16(0)
    elseif tag == M.TAG_INTEGER or tag == M.TAG_ENUM then
        w:u16(4)
        w:i32(value)
    elseif tag == M.TAG_BOOLEAN then
        w:u16(1)
        w:u8((value and value ~= 0) and 1 or 0)
    elseif tag == M.TAG_RESOLUTION then
        w:u16(9)
        w:i32(value.x)
        w:i32(value.y)
        w:u8(value.units or M.RESOLUTION_DPI)
    elseif tag == M.TAG_RANGE_OF_INTEGER then
        w:u16(8)
        w:i32(value.lower)
        w:i32(value.upper)
    elseif tag == M.TAG_TEXT_WITH_LANGUAGE or tag == M.TAG_NAME_WITH_LANGUAGE then
        w:u16(4 + #value.language + #value.text)
        w:str(value.language)
        w:str(value.text)
    elseif tag == M.TAG_DATE_TIME then
        w:u16(11)
        w:raw(value)
    elseif tag == M.TAG_BEG_COLLECTION then
        -- The collection itself is empty on the wire; its members follow as
        -- memberAttrName/value pairs until endCollection.
        w:u16(0)
        for _, member in ipairs(value.members or {}) do
            encodeAttribute(w, {
                tag = M.TAG_MEMBER_ATTR_NAME, name = "", values = { member.name },
            })
            encodeAttribute(w, { tag = member.tag, name = "", values = member.values })
        end
        w:u8(M.TAG_END_COLLECTION)
        w:u16(0)
        w:u16(0)
    elseif STRING_TAGS[tag] then
        w:str(tostring(value))
    else
        -- Unknown tags are passed through as opaque bytes.
        w:str(tostring(value))
    end
end

--- Writes one attribute: the first value carries the name, the others are
-- additional values of the same attribute and have an empty name.
encodeAttribute = function(w, attr)
    local values = attr.values
    if #values == 0 then
        w:u8(attr.tag)
        w:str(attr.name)
        encodeValue(w, attr.tag, nil)
        return
    end
    for i, value in ipairs(values) do
        w:u8(attr.tag)
        w:str(i == 1 and attr.name or "")
        encodeValue(w, attr.tag, value)
    end
end

-------------------------------------------------------------------------------
-- Message encoding / decoding
-------------------------------------------------------------------------------

--- Serialises a message to its wire format.
-- @tparam table message version_major/minor, operation_id or status_code,
--   request_id, groups, and optional trailing document `data`.
-- @treturn string
function M.encode(message)
    local w = M.newWriter()
    w:u8(message.version_major or 2)
    w:u8(message.version_minor or 0)
    w:u16(message.status_code or message.operation_id or 0)
    w:i32(message.request_id or 1)
    for _, group in ipairs(message.groups or {}) do
        w:u8(group.tag)
        for _, attr in ipairs(group.attributes or {}) do
            encodeAttribute(w, attr)
        end
    end
    w:u8(M.TAG_END_OF_ATTRIBUTES)
    if message.data then
        w:raw(message.data)
    end
    return w:build()
end

local function decodeValue(tag, raw)
    if tag == M.TAG_INTEGER or tag == M.TAG_ENUM then
        if #raw ~= 4 then
            return nil
        end
        return M.newReader(raw):i32()
    elseif tag == M.TAG_BOOLEAN then
        return #raw >= 1 and raw:byte(1) ~= 0
    elseif tag == M.TAG_RESOLUTION then
        if #raw ~= 9 then
            return nil
        end
        local r = M.newReader(raw)
        return M.resolution(r:i32(), r:i32(), r:u8())
    elseif tag == M.TAG_RANGE_OF_INTEGER then
        if #raw ~= 8 then
            return nil
        end
        local r = M.newReader(raw)
        return M.range(r:i32(), r:i32())
    elseif tag == M.TAG_TEXT_WITH_LANGUAGE or tag == M.TAG_NAME_WITH_LANGUAGE then
        local r = M.newReader(raw)
        return M.withLanguage(r:str(), r:str())
    end
    return raw
end

--- Parses a message. Returns nil plus an error when the bytes are malformed,
-- and nil plus "incomplete" when the attributes are not all there yet, so
-- that a streaming reader knows to wait for more data.
-- @treturn table message, with `data_offset` set to the first byte after the
--   end-of-attributes tag.
function M.decode(data)
    local ok, result = pcall(function()
        local r = M.newReader(data)
        local message = {
            version_major = r:u8(),
            version_minor = r:u8(),
            status_code = r:u16(),
            request_id = r:i32(),
            groups = {},
        }
        message.operation_id = message.status_code

        local group
        -- Innermost first: each entry is { value = <collection>, member = <attr> }.
        local stack = {}
        local pending_member
        local current

        while true do
            local tag = r:u8()
            if tag == M.TAG_END_OF_ATTRIBUTES then
                break
            end
            if M.isDelimiter(tag) then
                group = { tag = tag, attributes = {} }
                message.groups[#message.groups + 1] = group
                current = nil
                stack = {}
                pending_member = nil
            else
                local name = r:str()
                local raw = r:str()
                if tag == M.TAG_MEMBER_ATTR_NAME then
                    pending_member = raw
                elseif tag == M.TAG_END_COLLECTION then
                    local top = table.remove(stack)
                    current = top and top.previous or current
                    pending_member = nil
                else
                    local value = tag == M.TAG_BEG_COLLECTION and M.collection({}) or decodeValue(tag, raw)
                    local top = stack[#stack]
                    if top then
                        if pending_member then
                            top.value.members[#top.value.members + 1] = {
                                tag = tag, name = pending_member, values = { value },
                            }
                            top.member = top.value.members[#top.value.members]
                            pending_member = nil
                        elseif top.member then
                            local values = top.member.values
                            values[#values + 1] = value
                        end
                        if tag == M.TAG_BEG_COLLECTION then
                            stack[#stack + 1] = { value = value, previous = current }
                        end
                    else
                        if name ~= "" or not current then
                            if not group then
                                error("attribute outside of any group")
                            end
                            current = { tag = tag, name = name, values = {} }
                            group.attributes[#group.attributes + 1] = current
                        end
                        current.values[#current.values + 1] = value
                        if tag == M.TAG_BEG_COLLECTION then
                            stack[#stack + 1] = { value = value, previous = current }
                        end
                    end
                end
            end
        end
        message.data_offset = r.pos
        return message
    end)

    if not ok then
        if tostring(result):match("truncated IPP message") then
            return nil, "incomplete"
        end
        return nil, tostring(result)
    end
    return result
end

-------------------------------------------------------------------------------
-- Lookup helpers
-------------------------------------------------------------------------------

--- First attribute with that name, searching every group unless one is given.
function M.findAttribute(message, name, group_tag)
    for _, group in ipairs(message.groups or {}) do
        if not group_tag or group.tag == group_tag then
            for _, attr in ipairs(group.attributes) do
                if attr.name == name then
                    return attr
                end
            end
        end
    end
    return nil
end

--- First value of an attribute, or `default`.
function M.getValue(message, name, default)
    local attr = M.findAttribute(message, name)
    if not attr or #attr.values == 0 then
        return default
    end
    return attr.values[1]
end

--- Every value of an attribute, as a flat list.
function M.getValues(message, name)
    local attr = M.findAttribute(message, name)
    return attr and attr.values or {}
end

--- The first group with that delimiter tag.
function M.findGroup(message, tag)
    for _, group in ipairs(message.groups or {}) do
        if group.tag == tag then
            return group
        end
    end
    return nil
end

return M
