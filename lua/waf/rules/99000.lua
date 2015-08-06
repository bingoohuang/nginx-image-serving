-- Score threshold

local _M = {}

_M.version = "0.5"

local _rules = {
	{
		id = 99001,
		var = {
			type = "SCORE",
			pattern = "%{SCORE_THRESHOLD}",
			operator = "GREATER"
		},
		opts = { parsepattern = true },
		action = "DENY",
		description = "Request score greater than score threshold"
	}
}

function _M.rules()
	return _rules
end

return _M
