--[[--
Apple Raster (UNIRAST / `image/urf`) decoder.

iOS AirPrint always sends this instead of PDF. The file is a page count, then
for each page a 32-byte header and PackBits-compressed rows (PWG raster
style: a line-repeat byte, then inverted PackBits). Pages are wrapped in a
minimal PDF that KOReader can open.

@module koplugin.KOPrinter.urf
--]]

local M = {}

local MAGIC = "UNIRAST"
local PAGE_HEADER_SIZE = 32
local MAX_PIXELS = 40 * 1000 * 1000
local MAX_SIDE = 10000

local function signedByte(b)
    return b >= 128 and b - 256 or b
end

local function be32(n)
    n = math.floor(tonumber(n) or 0)
    if n < 0 then
        n = 0
    end
    local d = n % 256
    n = math.floor(n / 256)
    local c = n % 256
    n = math.floor(n / 256)
    local b = n % 256
    n = math.floor(n / 256)
    return string.char(n % 256, b, c, d)
end

local function readBe32(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not d then
        return nil
    end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

--- True when `data` starts with the UNIRAST magic.
function M.isUrf(data)
    return type(data) == "string" and data:sub(1, 7) == MAGIC
end

local function pixelSize(bpp)
    if bpp == 8 then
        return 1
    elseif bpp == 24 then
        return 3
    elseif bpp == 32 then
        return 4
    end
    return nil
end

--- Turns one packed pixel into an 8-bit gray sample.
-- colorspace 6 is CMYK; everything else is treated as gray or RGB(+A).
local function toGrayPixel(pixel, colorspace)
    local n = #pixel
    if n == 1 then
        return pixel
    end
    if n >= 4 and colorspace == 6 then
        return string.char(255 - pixel:byte(4))
    end
    local r, g, b = pixel:byte(1, 3)
    return string.char(math.min(255, math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)))
end

local function toGrayLine(line, bytes_per_pixel, colorspace)
    if bytes_per_pixel == 1 then
        return line
    end
    local out = {}
    for i = 1, #line, bytes_per_pixel do
        out[#out + 1] = toGrayPixel(line:sub(i, i + bytes_per_pixel - 1), colorspace)
    end
    return table.concat(out)
end

--- Decodes one raster row. `pos` is the byte offset of the first code.
-- @treturn string|nil the packed pixels
-- @treturn string|nil error
-- @treturn number next byte offset
local function decodeRow(data, pos, width, bytes_per_pixel)
    local parts = {}
    local written = 0
    local len = #data
    while written < width do
        if pos > len then
            return nil, "truncated PackBits row", pos
        end
        local code = signedByte(data:byte(pos))
        pos = pos + 1
        if code == -128 then
            parts[#parts + 1] = string.rep("\255", (width - written) * bytes_per_pixel)
            written = width
        elseif code >= 0 then
            if pos + bytes_per_pixel - 1 > len then
                return nil, "truncated repeated pixel", pos
            end
            local pixel = data:sub(pos, pos + bytes_per_pixel - 1)
            pos = pos + bytes_per_pixel
            local n = math.min(code + 1, width - written)
            parts[#parts + 1] = string.rep(pixel, n)
            written = written + n
        else
            local n = math.min(-code + 1, width - written)
            local bytes = n * bytes_per_pixel
            if pos + bytes - 1 > len then
                return nil, "truncated literal pixels", pos
            end
            parts[#parts + 1] = data:sub(pos, pos + bytes - 1)
            pos = pos + bytes
            written = written + n
        end
    end
    return table.concat(parts), nil, pos
end

local function decodePage(data, pos)
    if pos + PAGE_HEADER_SIZE - 1 > #data then
        return nil, "truncated URF page header", pos
    end
    local bpp = data:byte(pos)
    local colorspace = data:byte(pos + 1)
    local width = readBe32(data, pos + 12)
    local height = readBe32(data, pos + 16)
    local dpi = readBe32(data, pos + 20)
    pos = pos + PAGE_HEADER_SIZE

    local bytes_per_pixel = pixelSize(bpp)
    if not bytes_per_pixel then
        return nil, "unsupported URF bit depth " .. tostring(bpp), pos
    end
    if not width or not height or width < 1 or height < 1
        or width > MAX_SIDE or height > MAX_SIDE or width * height > MAX_PIXELS then
        return nil, string.format("URF page is too large (%sx%s)", tostring(width), tostring(height)), pos
    end
    if not dpi or dpi < 1 then
        dpi = 72
    end

    local rows = {}
    local y = 0
    while y < height do
        if pos > #data then
            return nil, "truncated URF raster", pos
        end
        local repeat_count = data:byte(pos) + 1
        pos = pos + 1
        local row, err, next_pos = decodeRow(data, pos, width, bytes_per_pixel)
        if not row then
            return nil, err, next_pos
        end
        pos = next_pos
        local gray = toGrayLine(row, bytes_per_pixel, colorspace)
        for _ = 1, repeat_count do
            if y >= height then
                break
            end
            rows[#rows + 1] = gray
            y = y + 1
        end
    end

    return {
        width = width,
        height = height,
        dpi = dpi,
        gray = table.concat(rows),
    }, nil, pos
end

--- Builds a one-image-per-page PDF from decoded grayscale pages.
local function buildPdf(pages)
    local out = {}
    local size = 0
    local function write(chunk)
        out[#out + 1] = chunk
        size = size + #chunk
    end

    write("%PDF-1.4\n%\128\129\130\131\n")

    local offsets = {}
    local function obj(n, body)
        offsets[n] = size
        write(string.format("%d 0 obj\n", n))
        write(body)
        if body:sub(-1) ~= "\n" then
            write("\n")
        end
        write("endobj\n")
    end

    -- 1 = catalog, 2 = pages tree; each printed page uses three objects.
    local kids = {}
    for i, page in ipairs(pages) do
        local page_obj = 3 + (i - 1) * 3
        local image_obj = page_obj + 1
        local content_obj = page_obj + 2
        kids[#kids + 1] = string.format("%d 0 R", page_obj)

        local wpt = page.width * 72 / page.dpi
        local hpt = page.height * 72 / page.dpi
        local content = string.format("q %.4f 0 0 %.4f 0 0 cm /Im Do Q\n", wpt, hpt)
        obj(page_obj, string.format(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.4f %.4f] "
            .. "/Resources << /XObject << /Im %d 0 R >> >> /Contents %d 0 R >>",
            wpt, hpt, image_obj, content_obj))
        obj(image_obj, string.format(
            "<< /Type /XObject /Subtype /Image /Width %d /Height %d "
            .. "/ColorSpace /DeviceGray /BitsPerComponent 8 /Length %d >>\n"
            .. "stream\n%s\nendstream",
            page.width, page.height, #page.gray, page.gray))
        obj(content_obj, string.format("<< /Length %d >>\nstream\n%sendstream", #content, content))
    end

    obj(2, string.format("<< /Type /Pages /Kids [%s] /Count %d >>",
        table.concat(kids, " "), #pages))
    obj(1, "<< /Type /Catalog /Pages 2 0 R >>")

    local xref_at = size
    local nobj = 3 + #pages * 3
    write(string.format("xref\n0 %d\n0000000000 65535 f \n", nobj))
    for i = 1, nobj - 1 do
        write(string.format("%010d 00000 n \n", offsets[i] or 0))
    end
    write(string.format("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n",
        nobj, xref_at))
    return table.concat(out)
end

--- Decodes a UNIRAST document into a PDF (DeviceGray images).
-- @treturn string|nil PDF bytes
-- @treturn string|nil error
function M.toPdf(data)
    if not M.isUrf(data) then
        return nil, "not a UNIRAST document"
    end
    if #data < 12 then
        return nil, "truncated URF header"
    end
    local page_count = readBe32(data, 9)
    if not page_count then
        return nil, "truncated URF header"
    end
    if page_count == 0 then
        page_count = 1
    end
    if page_count > 200 then
        return nil, "too many URF pages"
    end

    local pages = {}
    local pos = 13
    for i = 1, page_count do
        local page, err, next_pos = decodePage(data, pos)
        if not page then
            return nil, string.format("page %d: %s", i, err)
        end
        pages[#pages + 1] = page
        pos = next_pos
    end
    return buildPdf(pages)
end

--- Reads `path` and, when it is UNIRAST, writes a sibling `.pdf`.
-- Non-URF files are returned unchanged so PDF jobs stay as they are.
-- @treturn string|nil path of the file KOReader should open
-- @treturn string|nil error
function M.convertFile(path)
    local file, open_err = io.open(path, "rb")
    if not file then
        return nil, open_err
    end
    local magic = file:read(8)
    if not M.isUrf(magic or "") then
        file:close()
        return path
    end
    local data = magic .. (file:read("*a") or "")
    file:close()
    local pdf, err = M.toPdf(data)
    if not pdf then
        return nil, err
    end
    local out = path:gsub("%.[^/\\%.]+$", "") .. ".pdf"
    if out == path then
        out = path .. ".pdf"
    end
    local dest, write_err = io.open(out, "wb")
    if not dest then
        return nil, write_err
    end
    dest:write(pdf)
    dest:close()
    return out
end

--- Encodes grayscale (or RGB) pages as UNIRAST. Used by the tests.
-- Each page is `{ width, height, dpi, data, bpp = 8|24 }`.
function M.encode(pages)
    local out = { MAGIC .. "\0", be32(#pages) }
    for _, page in ipairs(pages) do
        local bpp = page.bpp or 8
        local bytes_per_pixel = pixelSize(bpp)
        assert(bytes_per_pixel, "encode: unsupported bpp")
        local data = page.data
        assert(#data == page.width * page.height * bytes_per_pixel, "encode: pixel count")
        out[#out + 1] = string.char(bpp, page.colorspace or 0, 0, 0)
        out[#out + 1] = be32(0) .. be32(0)
        out[#out + 1] = be32(page.width) .. be32(page.height) .. be32(page.dpi or 72)
        out[#out + 1] = be32(0) .. be32(0)
        local stride = page.width * bytes_per_pixel
        for y = 0, page.height - 1 do
            local row = data:sub(y * stride + 1, (y + 1) * stride)
            out[#out + 1] = string.char(0) -- this line is not repeated
            local x = 1
            while x <= page.width do
                local n = math.min(128, page.width - x + 1)
                -- Verbatim: code = 1-n, stored as an unsigned byte.
                out[#out + 1] = string.char((1 - n) % 256)
                out[#out + 1] = row:sub((x - 1) * bytes_per_pixel + 1, (x - 1 + n) * bytes_per_pixel)
                x = x + n
            end
        end
    end
    return table.concat(out)
end

return M
