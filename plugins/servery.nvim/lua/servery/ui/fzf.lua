local M = {}

local function ansi_hl(s, group)
	local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
	if not hl.fg then
		return s
	end
	local r = bit.rshift(bit.band(hl.fg, 0xFF0000), 16)
	local g = bit.rshift(bit.band(hl.fg, 0x00FF00), 8)
	local b = bit.band(hl.fg, 0x0000FF)
	return string.format("\27[38;2;%d;%d;%dm%s\27[0m", r, g, b, s)
end

local time = -99
local sessions = {} --[[@as servery.Session[] ]]

---@param session servery.Session
---@param hl? boolean
---@return string
local format_session = function(session, hl)
	local icon = session:icon()
	local active_time = session:time_since_start(time)
	local status = session:status()

	local pieces = {
		{ icon, "ServeryIcon" .. status },
		{ "  " },
		{ session:display_name(), "ServeryLine" .. status },
		active_time and { "  " },
		active_time and { active_time, "ServeryTime" },
	}

	local out = ""
	for _, p in ipairs(pieces) do
		out = out .. (hl and p[2] and ansi_hl(p[1], p[2]) or p[1])
	end
	return out
end

---@return servery.Session?
local get_session = function(text)
	for _, session in ipairs(sessions) do
		if format_session(session) == text then
			return session
		end
	end
end

---@type table<servery.action, fzf-lua.config.Action>
local fzf_actions = {
	switch = {
		---@param selection string[]
		fn = function(selection, _opts, _ctx)
			for _, text in ipairs(selection) do
				local session = get_session(text)
				if session then
					session:switch()
				end
			end
		end,
	},
	switch_and_detach = {
		---@param selection string[]
		fn = function(selection, _opts, _ctx)
			for _, text in ipairs(selection) do
				local session = get_session(text)
				if session then
					session:switch(true)
				end
			end
		end,
	},
	spawn = {
		---@param selection string[]
		fn = function(selection, _opts, _ctx)
			for _, text in ipairs(selection) do
				local session = get_session(text)
				if session then
					session:spawn_new()
					vim.uv.sleep(500)
				end
			end
		end,
		reload = true,
	},
	detach = {
		---@param selection string[]
		fn = function(selection, _opts, _ctx)
			for _, text in ipairs(selection) do
				local session = get_session(text)
				if session then
					session:detach()
					vim.uv.sleep(500)
				end
			end
		end,
		reload = true,
	},
}

M.select = function()
	if not FzfLua then
		vim.notify('[Servery] `FzfLua` not found. `ui = "fzf"` requires fzf-lua to be installed!', vim.log.levels.ERROR)
		return
	end

	local servery = require("servery")
	local cfg = servery.get_cfg()

	local get_items = function(fzf_cb)
		sessions = servery.list_sessions()
		time = os.time()

		for _, session in ipairs(sessions) do
			fzf_cb(format_session(session, true))
		end

		fzf_cb()
	end

	FzfLua.fzf_exec(get_items, {
		prompt = cfg.ui.prompt .. "> ",
		-- For some reason, unless actions is supplied as a function, it's
		-- impossible to override the default keymaps :(
		actions = function()
			local out = {}
			for key, action in pairs(cfg.ui.fzf_actions) do
				out[key] = fzf_actions[action]
					or vim.notify(
						string.format("[Servery] Action '%s' is not available for the fzf provider", action),
						vim.log.levels.WARN
					)
			end
			return out
		end,
	})
end

return M
