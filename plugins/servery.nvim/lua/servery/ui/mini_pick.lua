---@diagnostic disable: undefined-global
local M = {}

M.select = function()
	if not MiniPick then
		vim.notify(
			'[Servery] `MiniPick` not found. `ui = "mini_pick"` requires mini.pick to be installed!',
			vim.log.levels.ERROR
		)
		return
	end

	local servery = require("servery")
	local cfg = servery.get_cfg()

	local time = os.time()
	local sessions = {} --[[@as servery.Session[] ]]

	---@return table[]
	local get_sessions = function()
		sessions = servery.list_sessions() --[[@as table[] ]]
		time = os.time()
		for _, session in ipairs(sessions) do
			session.text = session:display_name()
		end
		return sessions
	end

	local ns = vim.api.nvim_create_namespace("servery_mini_pick")

	local show = function(buf_id, sessions_to_show, _query)
		local lines = {}
		local hl_data = {}
		for i, session in ipairs(sessions_to_show) do
			local icon = session:icon()
			local status = session:status()
			local name = session:display_name()
			local active_time = session:time_since_start(time) or ""
			local suffix = active_time ~= "" and ("  " .. active_time) or ""
			lines[i] = icon .. "  " .. name .. suffix

			local name_col = #icon + 2
			table.insert(hl_data, { i - 1, 0, #icon, "ServeryIcon" .. status })
			table.insert(hl_data, { i - 1, name_col, name_col + #name, "ServeryLine" .. status })
			if active_time ~= "" then
				local t_col = name_col + #name + 2
				table.insert(hl_data, { i - 1, t_col, t_col + #active_time, "ServeryTime" })
			end
		end

		vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
		vim.api.nvim_buf_clear_namespace(buf_id, ns, 0, -1)
		for _, h in ipairs(hl_data) do
			vim.api.nvim_buf_set_extmark(buf_id, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
		end
	end

	---@type table<servery.action, fun(session: servery.Session?): any>
	local mini_actions = {
		switch = function(session)
			if session then
				session:switch()
			end
			return true
		end,
		switch_and_detach = function(session)
			if session then
				session:switch(true)
			end
			return true
		end,
		spawn = function(session)
			if session then
				session:spawn_new()
				vim.defer_fn(function() MiniPick.set_picker_items(get_sessions()) end, 500)
			end
		end,
		detach = function(session)
			if session then
				session:detach()
				vim.defer_fn(function() MiniPick.set_picker_items(get_sessions()) end, 500)
			end
		end,
	}

	-- mini.pick mappings require `char` to be a single keystroke string like
	-- "<CR>", "<C-x>", etc. Normalize from servery's builtin key format.
	local normalize_key = function(key) return (key:gsub("^<enter>$", "<CR>"):gsub("^<Enter>$", "<CR>")) end

	local mappings = {}
	for key, action in pairs(cfg.ui.actions) do
		local fn = mini_actions[action]
		if fn then
			---@diagnostic disable-next-line: assign-type-mismatch
			mappings["servery_" .. action] = {
				char = normalize_key(key),
				func = function()
					local session = MiniPick.get_picker_matches().current --[[@as servery.Session?]]
					return fn(session)
				end,
			}
		else
			vim.notify(
				string.format("[Servery] Action '%s' is not available for the mini_pick provider", action),
				vim.log.levels.WARN
			)
		end
	end

	-- Disable mini.pick built-ins that share keys with servery's default actions.
	-- Setting a built-in mapping to "" is the supported way to disable it.
	mappings.choose_in_split = ""
	mappings.choose_in_vsplit = ""
	mappings.choose_in_tabpage = ""
	mappings.move_start = ""
	mappings.mark = ""
	mappings.choose = ""

	MiniPick.start({
		source = {
			items = get_sessions(),
			name = cfg.ui.prompt,
			show = show,
			choose = function(session)
				if session then
					session:switch()
				end
			end,
		},
		mappings = mappings,
	})
end

return M
