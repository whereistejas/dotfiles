local jj = require("jumanji.jj")

local M = {}

local MAX_AGE_MS = 60 * 1000

---@type table<string, { fetched: integer, by_branch: table<string, integer> }>
local cache = {}

--- The open merge requests of the repo's origin, as of the last fetch:
--- MR number by source branch.
---@param root string
---@return table<string, integer>
function M.get(root)
	return cache[root] and cache[root].by_branch or {}
end

--- Fetch the open merge requests you authored on origin, with glab, in the
--- background, unless they were fetched in the last minute. `on_done` runs on
--- the main loop once there are new ones. Without origin or glab, nothing
--- happens.
---@param root string
---@param on_done fun()
function M.fetch(root, on_done)
	local entry = cache[root]
	if entry and vim.uv.now() - entry.fetched < MAX_AGE_MS then return end
	cache[root] = { fetched = vim.uv.now(), by_branch = M.get(root) }

	local url = jj.remote_url(root, "origin")
	if not url or vim.fn.executable("glab") == 0 then return end

	local cmd = { "glab", "mr", "list", "--author=@me", "--per-page", "100", "-F", "json", "-R", url }
	vim.system(cmd, { cwd = root, text = true }, function(obj)
		if obj.code ~= 0 then return end

		vim.schedule(function()
			local by_branch = {}
			for _, mr in ipairs(vim.json.decode(obj.stdout)) do
				by_branch[mr.source_branch] = mr.iid
			end
			cache[root].by_branch = by_branch
			on_done()
		end)
	end)
end

return M
