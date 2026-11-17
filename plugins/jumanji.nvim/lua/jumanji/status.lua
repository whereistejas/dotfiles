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
--- and after every jj operation in the repo; re-read if the root's watcher
--- closed because the root was deleted and it has since come back.
---@param root string
---@return string
function M.get(root)
	if not cache[root] or not watch.watching(root) then
		if not vim.uv.fs_stat(root) then return "" end

		cache[root] = ""
		watch.start(root, refresh)
		refresh(root)
	end
	return cache[root]
end

return M
