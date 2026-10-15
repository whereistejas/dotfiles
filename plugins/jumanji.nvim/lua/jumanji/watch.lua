local jj = require("jumanji.jj")

local M = {}

-- One watcher per repo root, shared by everyone watching it:
-- { listeners = { [on_change] = integer }, handle = uv_fs_event_t, timer = uv_timer_t }
local watchers = {}

--- Call `on_change(root)` (debounced, on the main loop) after every jj
--- operation in the repo, whoever runs it: each one replaces the operation
--- head file. Each listener is called once per change, however often it
--- was started.
---@param root string
---@param on_change fun(root: string)
function M.start(root, on_change)
	local w = watchers[root]
	if not w then
		local handle = assert(vim.uv.new_fs_event())
		local timer = assert(vim.uv.new_timer())
		w = { listeners = {}, handle = handle, timer = timer }
		local heads = vim.fs.joinpath(jj.repo_dir(root), "op_heads", "heads")
		handle:start(heads, {}, function()
			timer:start(50, 0, vim.schedule_wrap(function()
				for listener in pairs(w.listeners) do listener(root) end
			end))
		end)
		watchers[root] = w
	end

	w.listeners[on_change] = (w.listeners[on_change] or 0) + 1
end

--- Release one `start` of `on_change` on the root; the last one closes the watcher.
---@param root string
---@param on_change fun(root: string)
function M.stop(root, on_change)
	local w = watchers[root]
	if not w or not w.listeners[on_change] then return end

	w.listeners[on_change] = w.listeners[on_change] - 1
	if w.listeners[on_change] == 0 then w.listeners[on_change] = nil end
	if next(w.listeners) then return end
	w.handle:close()
	w.timer:close()
	watchers[root] = nil
end

return M
