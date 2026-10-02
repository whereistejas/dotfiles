---@diagnostic disable: param-type-mismatch
local M = {}

---@type table<servery.action, table>
local snacks_actions = {
	switch = { "servery_switch", mode = { "i", "n" } },
	switch_and_detach = { "servery_switch_and_detach", mode = { "i", "n" } },
	spawn = { "servery_spawn", mode = { "i", "n" } },
	detach = { "servery_detach", mode = { "i", "n" } },
}

M.select = function()
	if not Snacks then
		vim.notify(
			'[Servery] `Snacks` not found. `ui = "snacks"` requires snacks.nvim to be installed!',
			vim.log.levels.ERROR
		)
		return
	end

	local servery = require("servery")
	local cfg = servery.get_cfg()

	local keys = {}
	for key, action in pairs(cfg.ui.actions) do
		keys[key] = snacks_actions[action]
			or vim.notify(
				string.format("[Servery] Action '%s' is not available for the snacks provider", action),
				vim.log.levels.WARN
			)
	end

	Snacks.picker.pick("servery_sessions", {
		title = cfg.ui.prompt,
		finder = function()
			local new_items = servery.list_sessions() --[[@as snacks.picker.finder.result]]
			for i, item in ipairs(new_items) do
				item.text = item:display_name()
				item.has_server = item.server ~= nil
				item.idx = i
			end
			return new_items
		end,
		---@param session servery.Session
		format = function(session, _picker)
			local icon = session:icon()
			local status = session:status()
			return {
				{ icon, "ServeryIcon" .. status },
				{ "  ", "Normal" },
				{ session:display_name(), "ServeryLine" .. status },
				{ "  ", "Normal" },
				{ session:time_since_start(), "ServeryTime" },
			}
		end,
		sort = { fields = { "has_server", "score:desc", "idx" } },
		layout = { preview = false },
		win = { input = { keys = keys } },
		actions = {
			---@param picker snacks.Picker
			---@param session servery.Session
			servery_switch = function(picker, session, _action)
				session:switch()
				picker:close()
			end,
			---@param session servery.Session
			servery_switch_and_detach = function(_picker, session, _action) session:switch(true) end,
			---@param picker snacks.Picker
			---@param session servery.Session
			servery_spawn = function(picker, session, _action)
				session:spawn_new()
				vim.defer_fn(function() picker:refresh() end, 500)
			end,
			---@param picker snacks.Picker
			---@param session servery.Session
			servery_detach = function(picker, session, _action)
				session:detach()
				vim.defer_fn(function() picker:refresh() end, 500)
			end,
		},
	})
end

return M
