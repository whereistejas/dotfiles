local jj = require("jumanji.jj")

local M = {}

-- One watcher per repo root, shared by every log of that root:
-- { count = integer, handle = uv_fs_event_t, timer = uv_timer_t }
local watchers = {}

--- Call `on_change` (debounced, on the main loop) after every jj operation in
--- the repo, whoever runs it: each one replaces the operation head file.
---@param root string
---@param on_change fun()
function M.start(root, on_change)
	local w = watchers[root]
	if w then
		w.count = w.count + 1
		return
	end

	local handle = assert(vim.uv.new_fs_event())
	local timer = assert(vim.uv.new_timer())
	local heads = vim.fs.joinpath(jj.repo_dir(root), "op_heads", "heads")
	handle:start(heads, {}, function()
		timer:start(50, 0, vim.schedule_wrap(on_change))
	end)
	watchers[root] = { count = 1, handle = handle, timer = timer }
end

--- Release one `start` of the root's watcher; the last one closes it.
---@param root string
function M.stop(root)
	local w = watchers[root]
	if not w then return end

	w.count = w.count - 1
	if w.count > 0 then return end
	w.handle:close()
	w.timer:close()
	watchers[root] = nil
end

return M
