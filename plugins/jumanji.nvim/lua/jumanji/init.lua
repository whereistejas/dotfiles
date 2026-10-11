local diff = require("jumanji.diff")
local jj = require("jumanji.jj")

local M = {}

local ns = vim.api.nvim_create_namespace("jumanji")

-- Log buffers, keyed by bufnr:
-- { root = string, revset = string?, rows = table, items = table, expanded = { [change_id] = true } }
local views = {}

-- Changed files per commit id: { { status = string, path = string } }
local file_cache = {}

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

local STATUS_HL = {
	A = "JumanjiFileAdded",
	D = "JumanjiFileDeleted",
}

-- The graph prefix for lines under a commit: its node becomes an edge.
local function graph_continuation(graph)
	local edge = "\u{2502}"
	local out = {}
	for _, ch in ipairs(vim.fn.split(graph, [[\zs]])) do
		out[#out + 1] = (ch == " " or ch == edge) and ch or edge
	end
	return table.concat(out)
end

-- Display items, one per buffer line: jj's rows plus, under each expanded
-- commit, its message lines and changed files.
local function build_items(view)
	local items = {}
	for _, row in ipairs(view.rows) do
		local c = row.commit
		items[#items + 1] = { kind = c and "commit" or "graph", graph = row.graph, commit = c }

		local files = c and view.expanded[c.change_id] and file_cache[c.commit_id]
		if files then
			local graph = graph_continuation(row.graph)
			for _, text in ipairs(c.message) do
				items[#items + 1] = { kind = "message", graph = graph, commit = c, text = text }
			end
			if #c.message > 0 and #files > 0 then
				items[#items + 1] = { kind = "message", graph = graph, commit = c, text = "" }
			end
			for _, file in ipairs(files) do
				items[#items + 1] = { kind = "file", graph = graph, commit = c, file = file }
			end
		end
	end
	return items
end

local function render(buf)
	local view = views[buf]
	view.items = build_items(view)

	local lines, line_marks = {}, {}
	for i, item in ipairs(view.items) do
		local push, finish = line_builder()
		if item.kind == "commit" then
			render_commit(push, item.graph, item.commit)
		else
			push(item.graph, "JumanjiGraph")
			if item.kind == "message" then
				push(item.text)
			elseif item.kind == "file" then
				push(item.file.status, STATUS_HL[item.file.status] or "JumanjiFileModified")
				push(" ")
				if item.file.source ~= item.file.path then
					push(item.file.source .. " \u{2192} ")
				end
				push(item.file.path)
			end
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
		local c = view.items[i].commit
		if view.items[i].kind == "commit" then
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
	local item = views[buf].items[lnum]
	return item and item.commit
end

local function move_to_commit(buf, win, change_id)
	for i, item in ipairs(views[buf].items) do
		if item.kind == "commit" and item.commit.change_id == change_id then
			-- With 'nostartofline', G keeps the cursor's display column.
			vim.api.nvim_win_call(win, function() vim.cmd("normal! " .. i .. "G") end)
			return
		end
	end
end

-- Fetch the file lists of the given commits that aren't cached yet, then call
-- `on_done`. Lists are keyed by commit id, which changes whenever a commit is
-- rewritten, so they never go stale.
local function load_files(root, commits, on_done)
	local pending = 1
	local function finish()
		pending = pending - 1
		if pending == 0 then on_done() end
	end

	for _, c in ipairs(commits) do
		if not file_cache[c.commit_id] then
			pending = pending + 1
			jj.files(root, c.commit_id, function(files, err)
				if files then
					file_cache[c.commit_id] = files
				else
					vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
				end
				finish()
			end)
		end
	end
	finish()
end

local function refresh(buf)
	local view = views[buf]
	jj.log(view.root, view.revset, function(rows, err)
		if not vim.api.nvim_buf_is_valid(buf) then return end
		if not rows then
			vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
			return
		end

		local expanded = {}
		for _, row in ipairs(rows) do
			if row.commit and view.expanded[row.commit.change_id] then
				expanded[#expanded + 1] = row.commit
			end
		end

		load_files(view.root, expanded, function()
			if not vim.api.nvim_buf_is_valid(buf) then return end

			-- Keep the cursor on the same change across refreshes.
			local cursors = {}
			for _, win in ipairs(vim.fn.win_findbuf(buf)) do
				local c = commit_at(buf, vim.api.nvim_win_get_cursor(win)[1])
				cursors[win] = c and c.change_id
			end

			view.rows = rows
			render(buf)

			for win, change_id in pairs(cursors) do
				move_to_commit(buf, win, change_id)
			end
		end)
	end)
end

local function expand(buf)
	local view = views[buf]
	local c = commit_at(buf, vim.fn.line("."))
	if not c or view.expanded[c.change_id] then return end

	view.expanded[c.change_id] = true
	load_files(view.root, { c }, function()
		if vim.api.nvim_buf_is_valid(buf) then render(buf) end
	end)
end

local function collapse(buf)
	local view = views[buf]
	local c = commit_at(buf, vim.fn.line("."))
	if not c or not view.expanded[c.change_id] then return end

	view.expanded[c.change_id] = nil
	render(buf)
	move_to_commit(buf, 0, c.change_id)
end

local function open_diff(buf, in_tab)
	local item = views[buf].items[vim.fn.line(".")]
	if not item or item.kind ~= "file" then return end
	diff.open(views[buf].root, item.commit, item.file, in_tab)
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
	vim.bo[buf].modifiable = false

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function() views[buf] = nil end,
	})

	vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close jumanji log" })
	vim.keymap.set("n", "R", function() refresh(buf) end, { buffer = buf, desc = "Refresh jumanji log" })
	vim.keymap.set("n", "l", function() expand(buf) end, { buffer = buf, desc = "Expand commit" })
	vim.keymap.set("n", "h", function() collapse(buf) end, { buffer = buf, desc = "Collapse commit" })
	vim.keymap.set("n", "o", function() open_diff(buf, false) end, { buffer = buf, desc = "Diff file in a split" })
	vim.keymap.set("n", "O", function() open_diff(buf, true) end, { buffer = buf, desc = "Diff file in a new tab" })

	views[buf] = { root = root, rows = {}, items = {}, expanded = {} }
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
	local is_new = not buf
	buf = buf or create_buf(root)

	views[buf].revset = revset
	vim.api.nvim_win_set_buf(0, buf)
	-- Set once the buffer is in its window, so ftplugin's :setlocal lands there.
	if is_new then vim.bo[buf].filetype = "jumanji" end
	refresh(buf)
end

return M
