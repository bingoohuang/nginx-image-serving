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
        sizePosition = option and option.sizePosition or "middle"
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

    for width, x, height in string.gmatch(opt.sizes, "(%d+)([xX])(%d+)") do
        if not width or not height then return opt.sizes .. " is in bad format" end
        local size = width .. x .. height
        local sizedFileName, err = createSizedFileName(opt, size)
        if err then return err end

        local targetFile = opt.targetPath .. sizedFileName

        if tonumber(width) <= maxWidth and tonumber(height) <= maxHeight then
            os.execute(opt.convertCmd .. " " .. imageFile
                    .. " -resize " .. size
                    .. " -unsharp 0x1 "
                    .. targetFile)
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
        sizePosition = "right"
    }
    ngx.header["Content-type"] = "text/plain"
    ngx.say(result)
end

return _M
