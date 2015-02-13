--[[
> curl -F "file=@2.jpg" "http://localhost:8001/upload?maxSize=1M&suffix=jpg|gif&path=html/demo1/"
[{"name":"KgjvZp7TuK.2.jpg","size":39181}]
> curl -F "file=@2.jpg" -F "file=@3.jpg" "http://localhost:8001/upload?maxSize=1M&suffix=jpg|gif&path=html/demo1/"
[{"name":"eeGfLclIDl.2.jpg","size":39181},{"name":"PEx68uqEhH.3.jpg","size":46644}]
> curl -F "file=@2.jpg" -F "file=@3.jpg" "http://localhost:8001/upload?maxSize=1M&suffix=txt&path=html/demo1/"
upload file type is not allowed.
> curl -F "file=@2.jpg" -F "file=@3.jpg" "http://localhost:8001/upload?maxSize=1M&suffix=txt&path=html/demo1/"
upload file type is not allowed.
> curl -F "file=@2.jpg" -F "file=@3.jpg" "http://localhost:8001/upload?maxSize=1M&suffix=jpg|gif&path=html/demo1/"
[{"name":"5wtUtecAmz.2.jpg","size":39181},{"name":"nW7PCi7zVD.3.jpg","size":46644}]
> curl -F "file=@2.jpg" -F "file=@3.jpg" "http://localhost:8001/upload?maxSize=10k&suffix=jpg&path=html/demo1/"
file is too large than allowed max size 10240
> curl  -F "file=@2.jpg" -F "file=@3.jpg" "http://localhost:8001/upload?path=/html/demo1/"
failed to make directory /html/demo1/
> curl  -F "file=@2.jpg" -F "file=@3.jpg" "http://localhost:8001/upload?maxSize=abcd&path=/html/demo1/"
maxSize is illegal, it should be number or with unit 'M' or 'k'.
]]

local upload = require "resty.upload"

local _M = {
    _VERSION = '0.1'
}

local function throwError(msg, httpCode, err)
    error({code = httpCode, msg = msg .. (err or "")})
end

local function parseMaxSize(maxSize)
    local match = ngx.re.match(maxSize, "^(\\d+)([mMkK])$")
    if match then
        local number, unit = match[1], match[2]
        if unit == "M" or unit == "m" then
            return tonumber(number) * 1024 * 1024
        elseif unit == "K" or unit == "k" then
            return tonumber(number) * 1024
        end
    elseif ngx.re.match(maxSize, "^(\\d+)$") then
        return tonumber(maxSize)
    end

    throwError("maxSize is illegal, it should be number or with unit 'M' or 'k'.", 480)
end

local function checkPath(path)
    if path then return path end

    throwError("path is required.", 482)
end

local function createUploadForm(config)
    local chunk_size = 8192
    local form, err = upload:new(chunk_size)
    if not form then
        throwError("failed to get upload form. ", 500, err)
    end

    form:set_timeout(config.timeout)
    return form
end

local function getFilename(res)
    local filename = ngx.re.match(res,'(.+)filename="(.+)"(.*)')
    if filename then
        return filename[2]
    else
        return ""
    end
end

local function checkSuffix(config, fileName)
    if "*" == config.suffix then return  end

    local pattern = ".+\\.(" .. config.suffix .. ")$"
    local lowerFileName = fileName:lower()
    if ngx.re.match(lowerFileName, pattern) then return end

    throwError("upload file type is not allowed.", 481, err)
end

local function createPathIfNotExist(config)
    if os.execute( "cd " .. config.path ) ~= 0 then
        if os.execute( "mkdir -p " .. config.path) ~= 0 then
            throwError("failed to make directory " .. config.path .. ".", 484);
        end
    end
end

local function openFile(config, fileName)
    local uploadFile, err = io.open(config.path .. "/" .. fileName, "w+")
    if not uploadFile then
        throwError("failed to open file " .. fileName .. ".", err)
    end

    return uploadFile
end

local function handleHeader(config, res)
    local fileName = getFilename(res)
    if "" == fileName then return nil end

    checkSuffix(config, fileName)

    createPathIfNotExist(config)

    local uploadFile = openFile(config, fileName)

    return {
        fileName = fileName,
        uploadFile = uploadFile
    }

end

local function checkMaxSize(uploadData, config)
    if 0 == config.maxSize then return end
    if uploadData.uploadFile:seek("end") <= config.maxSize then return end

    uploadData.uploadFile:close()
    os.remove(config.path .. uploadData.fileName)
    ngx.log(ngx.ERR, "upload file size over the limit")
    throwError("file is too large than allowed max size " .. config.maxSize .. ".", 483)
end

local function handleBody(config, uploadData, res)
    if not uploadData then return end

    uploadData.uploadFile:write(res)

    checkMaxSize(uploadData, config)
end

local function handleEnd(config, uploadData, uploadResult)
    if not uploadData then return end

    local size = uploadData.uploadFile:seek("end")
    uploadData.uploadFile:close()

    table.insert(uploadResult, {name = uploadData.fileName, size = size})
end

local function handleUpload(config)
    local uploadResult = {}
    local uploadData = nil
    local form = createUploadForm(config)

    while true do
        local typ, res, err = form:read()
        if not typ then
            throwError("failed to read type. ", 500, err)
        end

        if typ == "header" then
            if res[1] ~= "Content-Type" then
                uploadData = handleHeader(config, res[2])
            end
        elseif typ == "body" then
            handleBody(config, uploadData, res)
        elseif typ == "part_end" then
            handleEnd(config, uploadData, uploadResult)
            uploadData = nil
        elseif typ == "eof" then
            break
        end
    end

    return uploadResult
end

function _M.upload(maxSize, suffix, path)
    local config = {
        maxSize = parseMaxSize(maxSize or 0),
        suffix = (suffix or "*"):lower(),
        path = checkPath(path),
        timeout = timeout or 60000 -- 1 minute
    }

    return handleUpload(config, uploadResult)
        -- ngx.header["Content-type"] = "application/json"
        -- ngx.say(cjson.encode(uploadResult))
end

return _M


