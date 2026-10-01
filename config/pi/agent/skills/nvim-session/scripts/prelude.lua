local function is_code_win(win)
	return win ~= 0
		and vim.api.nvim_win_is_valid(win)
		and vim.api.nvim_win_get_config(win).relative == ""
		and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

local function code_win()
	local cur, prev = vim.api.nvim_get_current_win(), vim.fn.win_getid(vim.fn.winnr("#"))
	for _, win in ipairs({ cur, prev }) do
		if is_code_win(win) then
			return win
		end
	end
	return vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(is_code_win)
end

local function modified_files()
	return vim.iter(vim.fn.getbufinfo({ bufmodified = 1 }))
		:filter(function(b) return vim.bo[b.bufnr].buftype == "" end)
		:map(function(b) return b.name end)
		:totable()
end
