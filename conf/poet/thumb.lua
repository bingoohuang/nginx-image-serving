-- brew install ImageMagick
-- https://github.com/leafo/magick
--[[ 
"500x300"       -- Resize image such that the aspect ratio is kept,
                --  the width does not exceed 500 and the height does
                --  not exceed 300
"500x300!"      -- Resize image to 500 by 300, ignoring aspect ratio
"500x"          -- Resize width to 500 keep aspect ratio
"x300"          -- Resize height to 300 keep aspect ratio
"50%x20%"       -- Resize width to 50% and height to 20% of original
"500x300#"      -- Resize image to 500 by 300, but crop either top
                --  or bottom to keep aspect ratio
"500x300+10+20" -- Crop image to 500 by 300 at position 10,20
]]

local _M = {
    _VERSION = '0.1'
}

local magick = require("poet.magick")


local function return_not_found(msg)
	ngx.status = ngx.HTTP_NOT_FOUND
	ngx.header["Content-type"] = "text/html"
	ngx.say(msg or "not found")
	ngx.exit(0)
end


-- "/images/abcd/10x10/hello.png"
-- http://localhost:8001/images/K2iUntp9_ywl/300x/UVvteULmJ3.jpg
function _M.magick_thumb(imageFileName, thumbSizes)
	-- make sure the file exists
	local file = io.open(imageFileName)

	if not file then return_not_found() end

	file:close()

	local dest_fname = cache_dir .. ngx.md5(size .. "/" .. path) .. "." .. ext

	-- resize the image
	magick.thumb(source_fname, size, dest_fname)

	ngx.exec(ngx.var.request_uri)
end


return _M