-- Unit tests for ipp_message.lua. Run with: luajit tests/test_ipp_message.lua
-- Locate the plugin directory whatever the current directory is.
local plugin_dir = arg[0]:match("^(.*)/tests/[^/]*$") or (arg[0]:find("/") and "." or "..")
package.path = plugin_dir .. "/?.lua;" .. package.path
local M = require("ipp_message")

local failures, checks = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02X ", c:byte()) end))
end

-- Header round trip -----------------------------------------------------------
local data = M.encode{
    version_major = 2, version_minor = 0,
    operation_id = M.OP_GET_PRINTER_ATTRIBUTES,
    request_id = 42,
    groups = {
        { tag = M.TAG_OPERATION_ATTRIBUTES, attributes = {
            M.attr(M.TAG_CHARSET, "attributes-charset", "utf-8"),
            M.attr(M.TAG_NATURAL_LANGUAGE, "attributes-natural-language", "en"),
            M.attr(M.TAG_URI, "printer-uri", "ipp://kindle.local:631/ipp/print"),
        } },
    },
}
-- 1+1+2+4 header, then the group.
check(data:byte(1) == 2 and data:byte(2) == 0, "version bytes")
check(data:byte(3) == 0 and data:byte(4) == 0x0B, "operation-id bytes")
check(data:sub(-1) == string.char(M.TAG_END_OF_ATTRIBUTES), "ends with end-of-attributes")

local msg, err = M.decode(data)
check(msg, "decode header: " .. tostring(err))
check(msg.request_id == 42, "request-id")
check(msg.operation_id == M.OP_GET_PRINTER_ATTRIBUTES, "operation-id")
check(#msg.groups == 1 and msg.groups[1].tag == M.TAG_OPERATION_ATTRIBUTES, "one operation group")
check(M.getValue(msg, "attributes-charset") == "utf-8", "charset value")
check(M.getValue(msg, "printer-uri") == "ipp://kindle.local:631/ipp/print", "printer-uri value")
check(msg.data_offset == #data + 1, "data_offset with no document")

-- Every value type ------------------------------------------------------------
local all = M.encode{
    status_code = M.OK,
    request_id = 7,
    groups = {
        { tag = M.TAG_PRINTER_ATTRIBUTES, attributes = {
            M.attr(M.TAG_INTEGER, "queued-job-count", 0),
            M.attr(M.TAG_INTEGER, "negative", -12345),
            M.attr(M.TAG_INTEGER, "big", 2147483647),
            M.attr(M.TAG_BOOLEAN, "color-supported", false),
            M.attr(M.TAG_BOOLEAN, "printer-is-accepting-jobs", true),
            M.attr(M.TAG_ENUM, "printer-state", M.PRINTER_IDLE),
            M.attr(M.TAG_ENUM, "operations-supported", { M.OP_PRINT_JOB, M.OP_VALIDATE_JOB, M.OP_GET_PRINTER_ATTRIBUTES }),
            M.attr(M.TAG_RESOLUTION, "printer-resolution-default", M.resolution(300, 300)),
            M.attr(M.TAG_RANGE_OF_INTEGER, "copies-supported", M.range(1, 1)),
            M.attr(M.TAG_KEYWORD, "media-supported", { "custom_koreader_90.76x122.59mm", "iso_a4_210x297mm" }),
            M.attr(M.TAG_NO_VALUE, "printer-state-message"),
            M.attr(M.TAG_TEXT_WITH_LANGUAGE, "printer-info", M.withLanguage("en", "KOReader")),
        } },
    },
}
local decoded
decoded, err = M.decode(all)
check(decoded, "decode all types: " .. tostring(err))
check(decoded.status_code == M.OK, "status code")
check(M.getValue(decoded, "queued-job-count") == 0, "integer 0")
check(M.getValue(decoded, "negative") == -12345, "negative integer")
check(M.getValue(decoded, "big") == 2147483647, "max int32")
check(M.getValue(decoded, "color-supported") == false, "boolean false")
check(M.getValue(decoded, "printer-is-accepting-jobs") == true, "boolean true")
check(#M.getValues(decoded, "operations-supported") == 3, "1setOf enum count")
check(M.getValues(decoded, "operations-supported")[2] == M.OP_VALIDATE_JOB, "1setOf enum value")
local res = M.getValue(decoded, "printer-resolution-default")
check(res.x == 300 and res.y == 300 and res.units == M.RESOLUTION_DPI, "resolution")
local rng = M.getValue(decoded, "copies-supported")
check(rng.lower == 1 and rng.upper == 1, "rangeOfInteger")
check(M.getValues(decoded, "media-supported")[1] == "custom_koreader_90.76x122.59mm", "keyword 1setOf")
local no_value = M.findAttribute(decoded, "printer-state-message")
check(no_value and no_value.tag == M.TAG_NO_VALUE, "no-value tag survives")
local lang = M.getValue(decoded, "printer-info")
check(lang.language == "en" and lang.text == "KOReader", "textWithLanguage")

-- Collections -----------------------------------------------------------------
local media_size = M.collection{
    M.attr(M.TAG_INTEGER, "x-dimension", 9076),
    M.attr(M.TAG_INTEGER, "y-dimension", 12259),
}
local media_col = M.collection{
    M.attr(M.TAG_BEG_COLLECTION, "media-size", media_size),
    M.attr(M.TAG_KEYWORD, "media-type", "stationery"),
    M.attr(M.TAG_INTEGER, "media-top-margin", 0),
}
local coll = M.encode{
    status_code = M.OK, request_id = 1,
    groups = { { tag = M.TAG_PRINTER_ATTRIBUTES, attributes = {
        M.attr(M.TAG_BEG_COLLECTION, "media-col-default", media_col),
        M.attr(M.TAG_BEG_COLLECTION, "media-size-supported", { media_size, media_size }),
        M.attr(M.TAG_KEYWORD, "after-collection", "still-parsed"),
    } } },
}
local dc
dc, err = M.decode(coll)
check(dc, "decode collections: " .. tostring(err))
if dc then
    local outer = M.findAttribute(dc, "media-col-default")
    check(outer and outer.tag == M.TAG_BEG_COLLECTION, "media-col-default is a collection")
    local members = outer and outer.values[1].members or {}
    check(#members == 3, "media-col has 3 members, got " .. #members)
    check(members[1] and members[1].name == "media-size", "first member name")
    check(members[1] and members[1].tag == M.TAG_BEG_COLLECTION, "nested collection tag")
    local nested = members[1] and members[1].values[1].members or {}
    check(#nested == 2 and nested[1].name == "x-dimension" and nested[1].values[1] == 9076, "nested x-dimension")
    check(nested[2] and nested[2].values[1] == 12259, "nested y-dimension")
    check(members[2] and members[2].name == "media-type" and members[2].values[1] == "stationery", "keyword member")
    check(members[3] and members[3].values[1] == 0, "integer member")

    local setof = M.findAttribute(dc, "media-size-supported")
    check(setof and #setof.values == 2, "1setOf collection count: " .. tostring(setof and #setof.values))
    check(setof and setof.values[2] and #setof.values[2].members == 2, "second collection members")

    -- An attribute after a collection must land back in the group.
    check(M.getValue(dc, "after-collection") == "still-parsed", "attribute after collection")
end

-- Re-encoding a decoded message must produce the same bytes.
check(M.encode(dc) == coll, "collection re-encode is byte identical")
check(M.encode(decoded) == all, "all-types re-encode is byte identical\n" .. hex(M.encode(decoded)) .. "\n" .. hex(all))

-- Document data ---------------------------------------------------------------
local with_doc = M.encode{
    operation_id = M.OP_PRINT_JOB, request_id = 3,
    groups = { { tag = M.TAG_OPERATION_ATTRIBUTES, attributes = {
        M.attr(M.TAG_CHARSET, "attributes-charset", "utf-8"),
    } } },
    data = "%PDF-1.4\nhello",
}
local doc
doc, err = M.decode(with_doc)
check(doc, "decode with document: " .. tostring(err))
check(with_doc:sub(doc.data_offset) == "%PDF-1.4\nhello", "document bytes after data_offset")

-- Truncation must be reported as incomplete, not as an error ------------------
for cut = 1, #with_doc - #"%PDF-1.4\nhello" - 1 do
    local partial, perr = M.decode(with_doc:sub(1, cut))
    check(partial == nil and perr == "incomplete", "truncation at " .. cut .. " reports incomplete, got " .. tostring(perr))
end

-- Garbage must be rejected without raising ------------------------------------
local bad, berr = M.decode("\2\0\0\11\0\0\0\1\42\0\3abc")
check(bad == nil and berr ~= nil, "unknown delimiter-less attribute is rejected")

print(string.format("%s: %d checks, %d failures", arg[0], checks, failures))
os.exit(failures == 0 and 0 or 1)
