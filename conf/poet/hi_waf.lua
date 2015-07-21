-- refer to https://github.com/jaydipdave/quickdefencewaf
local _M = {}

local function trim(s)
    return s:match'^%s*(.*%S)' or ''
end

local function parseCookie(strCookie)
    local cookie = {}
    for k, v in string.gmatch(strCookie, "(%S+)=(%S+)") do
        if v:sub(v:len()) == ";" then
            cookie[k] = v:sub(1, v:len() - 1)
        else
            cookie[k] = v
        end
    end
    return cookie
end

local function parseCookies(self)
    for word in string.gmatch(self.raw_header, "Cookie: ([^\r\n]+)") do
        self.cookies = parseCookie(word)
    end
end

local function fetchRequest(self, conf)
    ngx.req.read_body()
    self.method       = ngx.req.get_method()
    self.args         = ngx.req.get_uri_args()
    self.post_args    = ngx.req.get_post_args()
    self.post_body    = ngx.req.get_body_data()
    self.headers      = ngx.req.get_headers()
    self.remote_ip    = conf and conf.useXRealIP and headers["X-Real-IP"] or ngx.var.remote_addr
    self.body         = ngx.var.request_body
    self.start_time   = ngx.req.start_time()
    self.http_version = ngx.req.http_version()
    self.raw_header   = ngx.req.raw_header()
    self.file_name    = ngx.req.get_body_file()
    self.body_data    = ngx.req.get_body_data()
    self.uri          = ngx.var.uri
    parseCookies(self)
end

local function matchRegex(self, data, regex, checkkeys)
    local typeData = type(data)
    if typeData == 'table' then
        for key, val in pairs(data) do
            if type(val) ~= 'string' then val = "" end

            if matchRegex(self, checkkeys and key or val, regex) then
                self.lastMatchInfo = key .. "=" .. val .. " is illegal"
                return true
            end
        end
    elseif typeData == 'string' then
        self.lastMatchInfo = data .. " is illegal"
        for regexItem in string.gmatch(regex, "([^\r\n]+)") do
            if regexItem and ngx.re.match(data, regexItem, "ijo") then
                return true
            end
        end
    end
    return false
end

local function ends(str, substr)
   return substr == '' or str:sub(-substr:len()) == substr
end

local function matchItem(self, data, field, fieldValue, regex, checkkeys)
    return data and field == fieldValue and matchRegex(self, data, regex)
end

local function match(self, fields, regex)
    for field in string.gmatch(fields, "([^,%s]+)") do
        if    matchItem(self, self.args      , field, "QUERY_STRING"   , regex)
           or matchItem(self, ngx.var.args   , field, "PLAIN_URI_QUERY", regex)
           or matchItem(self, self.args      , field, "QUERY_FIELDS"   , regex)
           or matchItem(self, self.method    , field, "METHOD"         , regex)
           or matchItem(self, self.uri       , field, "URI"            , regex)
           or matchItem(self, self.post_args , field, "POST_DATA"      , regex)
           or matchItem(self, self.post_args , field, "POST_FIELDS"    , regex, 1)
           or matchItem(self, self.post_body , field, "POST_BODY"      , regex)
           or matchItem(self, self.cookies   , field, "COOKIE_VALUES"  , regex)
           or matchItem(self, self.cookies   , field, "COOKIE_NAMES"   , regex, 1)
           or matchItem(self, self.headers   , field, "HEADER_VALUES"  , regex)
           or matchItem(self, self.headers   , field, "HEADER_NAMES"   , regex, 1)
        then return true end
    end

    return false
end

local function block(self, message)
    ngx.log(ngx.ERR, "[HiWAF][", tostring(message),
        "][BLOCKED]", "[MATCH: ", self.lastMatchInfo, "]")
    ngx.exit(401)
end

function _M.protect(conf)
    local lowerUri = ngx.var.uri:lower()
    local bypass = ends(lowerUri, ".jpg") or ends(lowerUri, ".jpeg")
            or ends(lowerUri, ".gif") or ends(lowerUri, ".png")
            or ends(lowerUri, ".js") or ends(lowerUri, ".css")
    if bypass then return end

    local self = {}
    fetchRequest(self, conf)

    local xss = [[\beval\b|\bwindow\b]]

    if match(self, "QUERY_STRING,HEADER_VALUES,COOKIE_VALUES,POST_DATA", xss) then
        block(self, "XSS")
    elseif not match(self, "METHOD", [[^GET$|^POST$]]) then
        block(self, "INVALID_METHOD_BLOCK")
    end
end

return _M
