local M = {}

M.buf = -99
M.ns = vim.api.nvim_create_namespace("servery.ui")
M.sessions = {} ---@type servery.Session[]

---@type table<servery.action, fun()>
local builtin_actions = {
	switch = function()
		local session = M.sessions[vim.api.nvim_win_get_cursor(0)[1] - 5]
		if session then
			session:switch()
			vim.cmd.bdelete()
		end
	end,
	spawn = function()
		local session = M.sessions[vim.api.nvim_win_get_cursor(0)[1] - 5]
		if session then
			session:spawn_new()
			vim.defer_fn(function() M.select() end, 400)
		end
	end,
	switch_and_detach = function()
		local session = M.sessions[vim.api.nvim_win_get_cursor(0)[1] - 5]
		if session then
			session:switch(true)
			-- Close the selection window when we switch to a new session
			vim.cmd.bdelete()
		end
	end,
	detach = function()
		local session = M.sessions[vim.api.nvim_win_get_cursor(0)[1] - 5]
		if session then
			session:detach()
			vim.defer_fn(function() M.select() end, 400)
		end
	end,
}

---@return [string, string[]][][]
local make_header_block = function()
	local cfg = require("servery").get_cfg()

	local keymaps_line = {}
	for key, action in pairs(cfg.ui.actions) do
		table.insert(keymaps_line, { " " .. action:gsub("_", " ") .. " ", { "CursorLine" } })
		table.insert(keymaps_line, { "(" .. key .. ") ", { "CursorLine", "Special" } })
		table.insert(keymaps_line, { "  ", {} })
	end

	return {
		{},
		{ { cfg.ui.prompt, { "Title" } } },
		{},
		keymaps_line,
		{},
	}
end

M.select = function()
	local servery = require("servery")
	local cfg = servery.get_cfg()

	M.sessions = servery.list_sessions()

	if not vim.api.nvim_buf_is_valid(M.buf) then
		M.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[M.buf].modifiable = false

		vim.keymap.set("n", "q", "<cmd>bd<cr>", { buf = M.buf })

		for key, action in pairs(cfg.ui.actions) do
			local fn = builtin_actions[action]
			if fn then
				vim.keymap.set("n", key, fn, { buf = M.buf })
			else
				vim.notify(
					string.format("[Servery] Action '%s' is not available for the builtin provider", action),
					vim.log.levels.WARN
				)
			end
		end
	end

	---@type [ integer, vim.api.keyset.set_extmark ][][]
	local marks = {}
	local lines = {}

	for _, parts in ipairs(make_header_block()) do
		local line = ""
		local line_marks = { { 0, { virt_text = { { "  " } }, virt_text_pos = "inline" } } }
		for _, part in ipairs(parts) do
			local mark_start = #line
			line = line .. part[1]
			for _, hl in ipairs(part[2]) do
				table.insert(line_marks, { mark_start, { hl_group = hl, end_col = #line } })
			end
		end

		table.insert(lines, line)
		table.insert(marks, line_marks)
	end

	for _, session in ipairs(M.sessions) do
		local starttime = session.server and session.server.starttime
		local spacer = starttime and "  " or ""
		local run_time = session:time_since_start() or ""
		local status = session:status()

		local line = ""
		local line_marks = {} ---@type [ integer, vim.api.keyset.set_extmark ][]

		---@type vim.api.keyset.set_extmark
		local indent_mark = {
			virt_text = { { "  " }, { session:icon(), "ServeryIcon" .. status }, { "  " } },
			virt_text_pos = "inline",
		}

		table.insert(line_marks, { 0, indent_mark })

		for _, part in ipairs({
			{ session:display_name(), "ServeryLine" .. status },
			{ spacer },
			{ run_time, "ServeryTime" },
		}) do
			local mark_start = #line
			line = line .. part[1]
			table.insert(line_marks, { mark_start, { hl_group = part[2], end_col = #line } })
		end

		table.insert(lines, line)
		table.insert(marks, line_marks)
	end

	vim.bo[M.buf].modifiable = true
	vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
	vim.bo[M.buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(M.buf, M.ns, 0, -1)
	for line, line_marks in ipairs(marks) do
		for _, m in ipairs(line_marks) do
			vim.api.nvim_buf_set_extmark(M.buf, M.ns, line - 1, m[1], m[2])
		end
	end

	local wins = vim.api.nvim_tabpage_list_wins(0)
	local win = vim.tbl_filter(function(w) return vim.api.nvim_win_get_buf(w) == M.buf end, wins)[1]
	if win then
		vim.api.nvim_set_current_win(win)
		return
	else
		local w = vim.api.nvim_open_win(M.buf, true, {
			style = "minimal",
			relative = "editor",
			col = math.floor(vim.o.columns * 0.1),
			row = math.floor(vim.o.lines * 0.1),
			width = math.floor(vim.o.columns * 0.8),
			height = math.floor(vim.o.lines * 0.8),
		})

		vim.api.nvim_create_autocmd({ "WinClosed", "BufWinLeave" }, {
			pattern = tostring(w),
			callback = function() vim.api.nvim_buf_delete(M.buf, {}) end,
		})
	end
end

return M
