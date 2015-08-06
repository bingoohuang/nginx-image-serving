local _M = {}

_M.version = "0.5"

-- ngx.log(ngx.ERR, "loading waf module")

-- instantiate a new instance of the module
local fw = require("waf.fw"):new()

-- setup FreeWAF to deny requests that match a rule
fw:set_option("mode", "ACTIVE")

-- fw:set_option("whitelist", "117.89.70.88")
-- fw:set_option("blacklist", "117.89.70.88")
-- fw:set_option("blacklist", "127.0.0.1")

-- 10000: Whitelist/blacklis handling
-- 11000: Local policty whitelisting
-- 20000: HTTP protocol violation
-- 21000: HTTP protocol anomalies
-- 35000: Malicious/suspect user agents
-- 40000: Generic attacks
-- 41000: SQLi
-- 42000: XSS
-- 90000: Custom rules/virtual patching
-- 99000: Anomaly score handling
-- fw:set_option("ignore_rule", 40294)

-- fw:set_option("ignore_ruleset", 20000)
-- fw:set_option("ignore_ruleset", 21000)
-- fw:set_option("ignore_ruleset", 35000)
-- fw:set_option("score_threshold", 10)

-- define a single allowed Content-Type value
-- fw:set_option("allowed_content_types", "text/xml")

-- defines multiple allowed Content-Type values
fw:set_option("allowed_content_types", { "text/html", "text/json", "application/json" })

-- fw:set_option("debug", true)
-- fw:set_option("debug_log_level", ngx.ERR)
-- fw:set_option("debug_log_level", ngx.DEBUG)
-- fw:set_option("event_log_level", ngx.WARN)

-- default verbosity. the client IP, request URI, rule match data, and rule ID will be logged
-- fw:set_option("event_log_verbosity", 1)

-- the rule description will be written in addition to existing data
-- fw:set_option("event_log_verbosity", 2)

-- the rule description, options and action will be written in addition to existing data
-- fw:set_option("event_log_verbosity", 3)

-- the entire rule definition, including the match pattern, will be written in addition to existing data
-- note that for some rule definitions, such as the XSS and SQLi rulesets, this pattern can be large
-- fw:set_option("event_log_verbosity", 4)

-- send event logs to the server error_log location (default)
-- fw:set_option("event_log_target", "error")

-- send event logs to a local file on disk
-- fw:set_option("event_log_target", "file")

-- send event logs to a remote UDP server
-- fw:set_option("event_log_target", "socket")

-- fw:set_option("event_log_target_host", "10.10.10.10")
-- fw:set_option("event_log_target_port", 9001)
-- fw:set_option("event_log_target_path", "logs/waf.log")

-- Default: 4096
-- fw:set_option("event_log_buffer_size", 8192)

-- flush the event log buffer every 30 seconds
-- fw:set_option("event_log_periodic_flush", 30)

fw:set_option("storage_zone", "waf")

-- run the firewall
function _M.protect()
    fw:exec()
end

return _M
