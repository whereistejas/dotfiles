local jj = require("jumanji.jj")

local M = {}

local ns = vim.api.nvim_create_namespace("jumanji")

-- Log buffers, keyed by bufnr: { root = string, revset = string?, rows = table }
local views = {}

-- Builds one line from highlighted chunks, recording the column range of each.
local function line_builder()
	local parts, marks, col = {}, {}, 0
	local function push(text, hl)
		if text == "" then return end
		parts[#parts + 1] = text
		if hl then marks[#marks + 1] = { col, col + #text, hl } end
		col = col + #text
	end
	local function finish()
		return table.concat(parts), marks
	end
	return push, finish
end

local function render_commit(push, graph, c)
	local wc = graph:find("@", 1, true)
	if c.working_copy and wc then
		push(graph:sub(1, wc - 1), "JumanjiGraph")
		push("@", "JumanjiWorkingCopy")
		push(graph:sub(wc + 1), "JumanjiGraph")
	else
		push(graph, "JumanjiGraph")
	end

	push(c.prefix, "JumanjiChangeIdPrefix")
	push(c.change_id:sub(#c.prefix + 1, 8), "JumanjiChangeId")
	if c.divergent then push("??", "JumanjiConflict") end
	push(" ")

	if c.bookmarks ~= "" then
		push(c.bookmarks, "JumanjiBookmark")
		push(" ")
	end
	if c.conflict then push("(conflict) ", "JumanjiConflict") end
	if c.empty then push("(empty) ", "JumanjiDim") end
	if c.description == "" then
		push("(no description set)", "JumanjiDim")
	else
		push(c.description, c.working_copy and "JumanjiWorkingCopy" or nil)
	end
end

local function render(buf)
	local view = views[buf]
	local lines, line_marks = {}, {}
	for i, row in ipairs(view.rows) do
		local push, finish = line_builder()
		if row.commit then
			render_commit(push, row.graph, row.commit)
		else
			push(row.graph, "JumanjiGraph")
		end
		lines[i], line_marks[i] = finish()
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for i, marks in ipairs(line_marks) do
		for _, m in ipairs(marks) do
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, m[1], { end_col = m[2], hl_group = m[3] })
		end
		local c = view.rows[i].commit
		if c then
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
				virt_text = {
					{ c.author, "JumanjiAuthor" }, { " " },
					{ c.timestamp, "JumanjiTimestamp" }, { " " },
					{ c.commit_id, "JumanjiCommitId" },
				},
				virt_text_pos = "right_align",
			})
		end
	end
end

local function commit_at(buf, lnum)
	local row = views[buf].rows[lnum]
	return row and row.commit
end

local function refresh(buf)
	local view = views[buf]
	jj.log(view.root, view.revset, function(rows, err)
		if not vim.api.nvim_buf_is_valid(buf) then return end
		if not rows then
			vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
			return
		end

		-- Keep the cursor on the same change across refreshes.
		local wins = vim.fn.win_findbuf(buf)
		local cursors = {}
		for _, win in ipairs(wins) do
			local c = commit_at(buf, vim.api.nvim_win_get_cursor(win)[1])
			cursors[win] = c and c.change_id
		end

		view.rows = rows
		render(buf)

		for win, change_id in pairs(cursors) do
			for i, row in ipairs(rows) do
				if row.commit and row.commit.change_id == change_id then
					vim.api.nvim_win_set_cursor(win, { i, 0 })
					break
				end
			end
		end
	end)
end

local function set_win_opts()
	vim.wo[0][0].wrap = false
	vim.wo[0][0].list = false
	vim.wo[0][0].number = false
	vim.wo[0][0].relativenumber = false
	vim.wo[0][0].signcolumn = "no"
	vim.wo[0][0].foldcolumn = "0"
	vim.wo[0][0].cursorline = true
end

local function close()
	local alt = vim.fn.bufnr("#")
	if alt ~= -1 and not views[alt] and vim.api.nvim_buf_is_valid(alt) then
		vim.api.nvim_win_set_buf(0, alt)
	else
		vim.cmd.enew()
	end
end

local function create_buf(root)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "jumanji://log/" .. root)
	vim.bo[buf].filetype = "jumanji"
	vim.bo[buf].modifiable = false

	vim.api.nvim_create_autocmd("BufWinEnter", { buffer = buf, callback = set_win_opts })
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function() views[buf] = nil end,
	})

	vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close jumanji log" })
	vim.keymap.set("n", "R", function() refresh(buf) end, { buffer = buf, desc = "Refresh jumanji log" })

	views[buf] = { root = root, rows = {} }
	return buf
end

local function find_root()
	local current = views[vim.api.nvim_get_current_buf()]
	if current then return current.root end
	return vim.fs.root(0, ".jj") or vim.fs.root(vim.fn.getcwd(), ".jj")
end

--- Open the commit log for the current repo in the current window.
---@param revset string? defaults to jj's `revsets.log`
function M.open(revset)
	local root = find_root()
	if not root then
		vim.notify("jumanji: not inside a jj repo", vim.log.levels.ERROR)
		return
	end

	local buf
	for b, view in pairs(views) do
		if view.root == root then buf = b end
	end
	buf = buf or create_buf(root)

	views[buf].revset = revset
	vim.api.nvim_win_set_buf(0, buf)
	refresh(buf)
end

return M
