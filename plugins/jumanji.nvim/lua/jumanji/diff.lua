local jj = require("jumanji.jj")

local M = {}

local function find_buf(name)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf) == name then return buf end
	end
end

-- A read-only scratch buffer holding one side of the diff.
local function side_buf(name, path, text)
	local existing = find_buf(name)
	if existing then return existing end

	local lines = vim.split(text, "\n", { plain = true })
	if lines[#lines] == "" then table.remove(lines) end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, name)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ""
	return buf
end

-- Fetch one side's content; sides that don't exist (added/deleted) are empty.
local function load_side(root, rev, path, exists, on_done)
	if not exists then
		on_done("")
		return
	end
	jj.file_show(root, rev, path, function(text, err)
		if not text then
			vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
			return
		end
		on_done(text)
	end)
end

-- The tab's before/after diff windows from an earlier `o`, if both still exist.
local function tab_diff_wins()
	local wins = vim.t.jumanji_diff
	if wins and vim.api.nvim_win_is_valid(wins[1]) and vim.api.nvim_win_is_valid(wins[2]) then
		return wins[1], wins[2]
	end
end

local function show(before, after, in_tab)
	local before_win, after_win
	if in_tab then
		vim.cmd("tab sbuffer " .. after)
		after_win = vim.api.nvim_get_current_win()
		vim.cmd("leftabove vertical sbuffer " .. before)
		before_win = vim.api.nvim_get_current_win()
	else
		before_win, after_win = tab_diff_wins()
		if before_win then
			vim.api.nvim_win_set_buf(before_win, before)
			vim.api.nvim_win_set_buf(after_win, after)
		else
			vim.cmd("belowright sbuffer " .. after)
			after_win = vim.api.nvim_get_current_win()
			vim.cmd("leftabove vertical sbuffer " .. before)
			before_win = vim.api.nvim_get_current_win()
			vim.t.jumanji_diff = { before_win, after_win }
		end
	end

	for _, win in ipairs({ before_win, after_win }) do
		vim.api.nvim_win_call(win, function() vim.cmd.diffthis() end)
	end
	vim.api.nvim_set_current_win(after_win)
end

--- Open a commit's change to one file as a side-by-side diff.
---@param root string
---@param commit table
---@param file table { status, source, path }
---@param in_tab boolean open in a new tab instead of a split
function M.open(root, commit, file, in_tab)
	local parent = commit.commit_id .. "-"
	local id = commit.commit_id

	load_side(root, parent, file.source, file.status ~= "A", function(before_text)
		load_side(root, id, file.path, file.status ~= "D", function(after_text)
			local before = side_buf(("jumanji://%s-/%s"):format(id, file.source), file.source, before_text)
			local after = side_buf(("jumanji://%s/%s"):format(id, file.path), file.path, after_text)
			show(before, after, in_tab)
		end)
	end)
end

return M
