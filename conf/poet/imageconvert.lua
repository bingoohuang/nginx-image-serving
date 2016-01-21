local _M = {
    _VERSION = '0.1'
}

local function isFileOrDir(name)
    if type(name) ~= "string" then return false end

    return os.rename(name, name) and true or false
end

local function isFile(name)
    if not isFileOrDir(name) then return false end

    local f = io.open(name, "r")
    if f and f:read() then f:close() return true end
end

local function isDir(name)
    local response = os.execute("cd " .. name)
    return response == 0 and true or false
end

local function addTrailingSlash(path)
    if string.sub(path, -1) ~= "/" then
        return path .. "/"
    else
        return path
    end
end

local function parseImageOriginalSize(opt, imageFile)
    local proc = io.popen(opt.identifyCmd .. " -format \"%wX%h\" " .. imageFile,  "r")
    local widthHeight = proc:read("*a") proc:close()
    local width, height = widthHeight:match("(%d+)[Xx](%d+)")
    return tonumber(width), tonumber(height)
end

local function createPathIfNotExist(path)
    if os.execute( "cd " .. path ) ~= 0 then
        if os.execute( "mkdir -p " .. path) ~= 0 then
            return "failed to make directory " .. path
        end
    end

    return "ok"
end

local function checkOpt(opt)
    if not opt.srcPath or not isDir(opt.srcPath) then
        return "src path " .. (opt.srcPath or "nil") .. " is unkown"
    end
    if not opt.targetPath then
        return "target path ".. (opt.targetPath or "nil") .. " is unkown"
    end
    if not opt.sizes then
        return "sizes " .. (opt.sizes or "nil") .. " is unkown"
    end

    local result = createPathIfNotExist(opt.targetPath)
    if result ~= "ok" then return result end
    return "ok"
end

local function unescapeUri(param)
    return param and ngx.unescape_uri(param) or param
end

local function createSizedFileName(opt, size)
    if opt.sizePosition == "left" then
        return size .. "." .. opt.fileName, nil
    elseif opt.sizePosition == "middle" then
        return string.gsub(opt.fileName, "%.%w+$", "." .. size .. "%1"), nil
    elseif opt.sizePosition == "right" then
        return opt.fileName .. "." .. size, nil
    else
        return nil, "sizePosition " .. opt.sizePosition
            .. " is illegal, should be left, middle or right"
    end
end

function _M.convert(option)
    local opt = {
        convertCmd = option and option.convertCmd or "convert",
        identifyCmd = option and option.identifyCmd or "identify",
        srcPath = unescapeUri(option and option.srcPath),
        targetPath = unescapeUri(option and option.targetPath),
        fileName = unescapeUri(option and option.fileName),
        sizes = unescapeUri(option and option.sizes),
        sizePosition = option and option.sizePosition or "middle",
        crop = option and option.crop or "true"
    }

    ngx.log(ngx.INFO, "srcPath " .. " " .. (opt.srcPath or "nil"))
    ngx.log(ngx.INFO, "targetPath " .. (opt.targetPath or "nil"))
    ngx.log(ngx.INFO, "fileName " .. (opt.fileName or "nil"))
    ngx.log(ngx.INFO, "sizes " .. (opt.sizes or "nil"))

    local result = checkOpt(opt)
    if result ~= "ok" then return result end

    opt.srcPath = addTrailingSlash(opt.srcPath)
    opt.targetPath = addTrailingSlash(opt.targetPath)

    local srcFile = opt.srcPath .. opt.fileName
    ngx.log(ngx.ERR, "srcFile " .. srcFile)

    if not isFile(srcFile) then return "file does not exist" end

    local imageFile = opt.targetPath .. opt.fileName
    os.execute(opt.convertCmd .. " " .. srcFile .. " -auto-orient -strip " .. imageFile)
    local maxWidth, maxHeight = parseImageOriginalSize(opt, imageFile)

    --[[
    经测试，发现-unsharp 0x1选项会使得切图很慢。大概3M左右的图片切5种尺寸，需要10秒。
    去掉该选项后，可以降到到2秒左右。
    #!/bin/bash

    date "+TIME: %H:%M:%S"
    convert 123.jpg -unsharp 0x1 -resize 100X100^ -gravity center -extent  100X100 100X100.jpg
    convert 123.jpg -unsharp 0x1 -resize 90X60^   -gravity center -extent  90X60   90X60.jpg
    convert 123.jpg -unsharp 0x1 -resize 80X80^   -gravity center -extent  80X80   80X80.jpg
    convert 123.jpg -unsharp 0x1 -resize 46X46^   -gravity center -extent  46X46   46X46.jpg
    convert 123.jpg -unsharp 0x1 -resize 325X240^ -gravity center -extent  325X240 325X240.jpg
    date "+TIME: %H:%M:%S"
    ]]--

    for width, x, height in string.gmatch(opt.sizes, "(%d+)([xX])(%d+)") do
        if not width or not height then return opt.sizes .. " is in bad format" end
        local size = width .. x .. height
        local sizedFileName, err = createSizedFileName(opt, size)
        if err then return err end

        local targetFile = opt.targetPath .. sizedFileName

        if tonumber(width) <= maxWidth and tonumber(height) <= maxHeight then
            --  http://www.imagemagick.org/Usage/resize/#noaspect
            local cmd = opt.convertCmd .. " " .. imageFile .. " -unsharp 0x1 -resize " .. size
            if opt.crop == "true" then
                cmd = cmd .. "^ -gravity center -extent " .. size
            end
            local result = os.execute(cmd .. " " .. targetFile)
            if result ~= 0 then return "failed to resize file,"
                + " this may be caused by imagemagick install problem" end
        end
    end

    return "ok"
end

function _M.convertImage ()
    local result = _M.convert {
        srcPath = ngx.var.arg_src,
        targetPath = ngx.var.arg_target,
        fileName = ngx.var.arg_file,
        sizes = ngx.var.arg_sizes,
        -- left: 100X100.xxx.jpg, middle:xxx.100X100.jpg, right: xxx.jpg.100X100
        sizePosition = "right",
        crop = "true"
    }
    ngx.header["Content-type"] = "text/plain"
    ngx.say(result)
end

return _M
