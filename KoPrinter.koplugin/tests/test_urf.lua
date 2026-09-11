-- Unit tests for urf.lua. Run with: luajit tests/test_urf.lua
local plugin_dir = arg[0]:match("^(.*)/tests/[^/]*$") or (arg[0]:find("/") and "." or "..")
package.path = plugin_dir .. "/?.lua;" .. package.path

local Urf = require("urf")

local failures, checks = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- A 4x2 grayscale page: two distinct rows, second row repeated in the file
-- through the encoder (one row each, no line-repeat).
local gray = string.char(
    10, 20, 30, 40,
    200, 210, 220, 230
)
local urf = Urf.encode{ { width = 4, height = 2, dpi = 72, data = gray, bpp = 8 } }
check(Urf.isUrf(urf), "magic is UNIRAST")
check(not Urf.isUrf("%PDF-1.4"), "PDF is not URF")

local pdf, err = Urf.toPdf(urf)
check(pdf and pdf:sub(1, 5) == "%PDF-", "decodes to a PDF: " .. tostring(err))
check(pdf and pdf:find("/DeviceGray", 1, true), "PDF image is grayscale")
check(pdf and pdf:find("/Width 4", 1, true) and pdf:find("/Height 2", 1, true),
      "PDF image keeps the pixel size")
check(pdf and pdf:find(gray, 1, true), "gray pixels survive into the PDF stream")

-- RGB is flattened to gray (red → dark, white → white).
local rgb = string.char(255, 0, 0, 255, 255, 255)
local rgb_urf = Urf.encode{ { width = 2, height = 1, dpi = 300, data = rgb, bpp = 24, colorspace = 1 } }
local rgb_pdf = assert(Urf.toPdf(rgb_urf))
-- 0.299*255 ≈ 76 for red; white stays 255.
check(rgb_pdf:find(string.char(76, 255), 1, true)
      or rgb_pdf:find(string.char(75, 255), 1, true),
      "RGB page is converted to gray")

-- PackBits: a solid white line uses the 0x80 fill, plus a repeated line.
local function packSolid(width, height, dpi, value)
    local out = { "UNIRAST\0", string.char(0, 0, 0, 1),
        string.char(8, 0, 0, 0),
        string.char(0, 0, 0, 0, 0, 0, 0, 0),
        string.char(0, 0, 0, width), string.char(0, 0, 0, height),
        string.char(0, 0, 0, dpi),
        string.char(0, 0, 0, 0, 0, 0, 0, 0) }
    -- One encoded row, repeated `height` times: line-repeat = height-1, then 0x80.
    out[#out + 1] = string.char(height - 1, 128)
    if value ~= 255 then
        -- Repeat `value` across the line with a single 0x00+pixel would only
        -- paint one pixel; emit one repeat-all instead.
        out[#out] = string.char(height - 1, width - 1, value)
    end
    return table.concat(out)
end

local white = packSolid(8, 3, 72, 255)
local white_pdf = assert(Urf.toPdf(white))
check(white_pdf:find(string.rep("\255", 8 * 3), 1, true), "0x80 fills the line with white")

local black = packSolid(5, 2, 72, 0)
local black_pdf = assert(Urf.toPdf(black))
check(black_pdf:find(string.rep("\0", 10), 1, true), "repeated pixel paints the whole line")

-- convertFile leaves a real PDF alone and replaces a .urf sibling.
local tmp = os.tmpname()
os.remove(tmp)
local pdf_path = tmp .. ".pdf"
local urf_path = tmp .. ".urf"
local f = assert(io.open(pdf_path, "wb"))
f:write("%PDF-1.4 leftover\n")
f:close()
local same = Urf.convertFile(pdf_path)
check(same == pdf_path, "PDF path is returned unchanged")

f = assert(io.open(urf_path, "wb"))
f:write(urf)
f:close()
local converted, conv_err = Urf.convertFile(urf_path)
check(converted and converted:sub(-4) == ".pdf", "URF is written next to the source: " .. tostring(conv_err))
local out = converted and io.open(converted, "rb")
local out_data = out and out:read("*a")
if out then out:close() end
check(out_data and out_data:find(gray, 1, true), "converted PDF contains the gray page")
os.remove(pdf_path)
os.remove(urf_path)
if converted then os.remove(converted) end

check(not Urf.toPdf("hello"), "garbage is rejected")
check(not Urf.toPdf("UNIRAST\0\0\0\0\1"), "truncated raster is rejected")

print(string.format("%s: %d checks, %d failures", arg[0], checks, failures))
os.exit(failures == 0 and 0 or 1)
