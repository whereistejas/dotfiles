local jj = require("jumanji.jj")
local watch = require("jumanji.watch")

local M = {}

-- Statusline text per repo root; "" until the first read finishes.
local cache = {}

local function refresh(root)
	jj.working_copy(root, function(wc)
		cache[root] = (wc.workspace and ("[" .. wc.workspace .. "] ") or "") .. wc.change_id
		vim.cmd.redrawstatus({ bang = true })
	end)
end

--- The root's workspace, unless it's the default one, and its working copy's
--- change id, e.g. "[feature] yluyrkvs". Read in the background on first use
--- and after every jj operation in the repo.
---@param root string
---@return string
function M.get(root)
	if not cache[root] then
		cache[root] = ""
		watch.start(root, refresh)
		refresh(root)
	end
	return cache[root]
end

return M
