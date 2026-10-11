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

-- Fetch the file lists of the given commits that aren't cached yet. Lists are
-- keyed by commit id, which changes whenever a commit is rewritten, so they
-- never go stale.
local function load_files(root, commits)
	local missing = {}
	for _, c in ipairs(commits) do
		if not file_cache[c.commit_id] then missing[#missing + 1] = c.commit_id end
	end
	if #missing == 0 then return end

	local files, err = jj.files(root, missing)
	if not files then
		vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
		return
	end
	for id, list in pairs(files) do file_cache[id] = list end
end

local function refresh(buf)
	local view = views[buf]
	local rows, err = jj.log(view.root, view.revset)
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
	load_files(view.root, expanded)

	view.rows = rows
	render(buf)
end

--- Expand the commit under the cursor: show its message and changed files.
function M.expand()
	local buf = vim.api.nvim_get_current_buf()
	local view = views[buf]
	local c = commit_at(buf, vim.fn.line("."))
	if not c or view.expanded[c.change_id] then return end

	view.expanded[c.change_id] = true
	load_files(view.root, { c })
	render(buf)
end

--- Collapse the commit under the cursor (or the one the cursor is inside).
function M.collapse()
	local buf = vim.api.nvim_get_current_buf()
	local view = views[buf]
	local c = commit_at(buf, vim.fn.line("."))
	if not c or not view.expanded[c.change_id] then return end

	view.expanded[c.change_id] = nil
	render(buf)
	for i, item in ipairs(view.items) do
		if item.kind == "commit" and item.commit.change_id == c.change_id then
			-- With 'nostartofline', G keeps the cursor's display column.
			vim.cmd("normal! " .. i .. "G")
			return
		end
	end
end

--- Open the file under the cursor as a diff against the commit's parent.
---@param in_tab boolean open in a new tab instead of a split
function M.open_diff(in_tab)
	local view = views[vim.api.nvim_get_current_buf()]
	local item = view.items[vim.fn.line(".")]
	if not item or item.kind ~= "file" then return end
	diff.open(view.root, item.commit, item.file, in_tab)
end

-- A log is the buffer jumanji://log<root>[//<revset>], read by the BufReadCmd
-- autocmd in plugin/jumanji.lua.
local function log_url(root, revset)
	return "jumanji://log" .. root .. (revset and ("//" .. revset) or "")
end

local function parse_log_url(name)
	local root, revset = name:match("^jumanji://log(/.-)//(.+)$")
	return root or name:match("^jumanji://log(/.+)$"), revset
end

--- BufReadCmd handler for log buffers; also what `:edit` runs to refresh one.
---@param buf integer
function M.read(buf)
	if not views[buf] then
		local root, revset = parse_log_url(vim.api.nvim_buf_get_name(buf))
		views[buf] = { root = root, revset = revset, rows = {}, items = {}, expanded = {} }
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function() views[buf] = nil end,
		})
	end

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "jumanji"
	refresh(buf)
end

--- Re-read every log buffer shown in a window, after jj changed the repo.
function M.refresh_all()
	for buf in pairs(views) do
		local win = vim.fn.win_findbuf(buf)[1]
		if win then vim.api.nvim_win_call(win, function() vim.cmd.edit() end) end
	end
end

--- Open the commit log for the current repo in a new horizontal split.
---@param revset string? defaults to jj's `revsets.log`
function M.open(revset)
	local current = views[vim.api.nvim_get_current_buf()]
	local root = current and current.root or vim.fs.root(0, ".jj") or vim.fs.root(vim.fn.getcwd(), ".jj")
	if not root then
		vim.notify("jumanji: not inside a jj repo", vim.log.levels.ERROR)
		return
	end

	local url = log_url(root, revset)
	local loaded = vim.fn.bufloaded(url) == 1
	vim.cmd("split " .. vim.fn.fnameescape(url))
	-- :split only reads a buffer that isn't loaded; re-read a loaded one.
	if loaded then vim.cmd.edit() end
end

return M
