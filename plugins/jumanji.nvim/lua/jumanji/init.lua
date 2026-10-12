local diff = require("jumanji.diff")
local jj = require("jumanji.jj")
local watch = require("jumanji.watch")

local M = {}

local ns = vim.api.nvim_create_namespace("jumanji")

-- Log buffers, keyed by bufnr:
-- { root = string, revset = string?, rows = table, items = table, expanded = { [change_id] = true },
--   selected = { [change_id] = true }, stale = boolean? (the repo changed while no window showed it) }
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
			if view.selected[c.change_id] then
				vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { sign_text = "\u{25cf}", sign_hl_group = "JumanjiSelected" })
			end
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

-- What a line shows, stable across re-renders: nil for graph-only lines.
local function item_key(item)
	if not item or not item.commit then return nil end
	local detail = item.file and item.file.path or item.text or ""
	return table.concat({ item.commit.change_id, item.kind, detail }, "\0")
end

local function refresh(buf)
	local view = views[buf]
	view.stale = nil
	local rows, err = jj.log(view.root, view.revset)
	if not rows then
		vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
		return
	end

	local cursors = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local pos = vim.api.nvim_win_get_cursor(win)
		cursors[win] = { key = item_key(view.items[pos[1]]), pos = pos }
	end

	local expanded = {}
	for _, row in ipairs(rows) do
		if row.commit and view.expanded[row.commit.change_id] then
			expanded[#expanded + 1] = row.commit
		end
	end
	load_files(view.root, expanded)

	local shown = {}
	for _, row in ipairs(rows) do
		if row.commit then shown[row.commit.change_id] = true end
	end
	for id in pairs(view.selected) do
		if not shown[id] then view.selected[id] = nil end
	end

	view.rows = rows
	render(buf)

	-- Keep each cursor on what it was on, wherever that moved to.
	for win, cursor in pairs(cursors) do
		local lnum = cursor.pos[1]
		for i, item in ipairs(view.items) do
			if cursor.key and item_key(item) == cursor.key then
				lnum = i
				break
			end
		end
		lnum = math.max(1, math.min(lnum, #view.items))
		vim.api.nvim_win_set_cursor(win, { lnum, cursor.pos[2] })
	end
end

--- Re-read the root's logs after the repo changed: the ones in a window now,
--- the rest once they're shown again.
---@param root string
function M.refresh_root(root)
	for buf, view in pairs(views) do
		if view.root == root then
			if #vim.fn.win_findbuf(buf) > 0 then
				refresh(buf)
			else
				view.stale = true
			end
		end
	end
end

--- Snapshot the working copy of every repo with a log open, so edits made
--- outside jj show up. Logs refresh through their watchers.
---@param path string? only the repo containing this file
function M.snapshot(path)
	-- Compare real paths: a symlink (like macOS's /tmp) can lead to either side.
	path = path and vim.uv.fs_realpath(path)
	local roots = {}
	for _, view in pairs(views) do
		local real_root = vim.uv.fs_realpath(view.root) or view.root
		if not path or vim.startswith(path, real_root .. "/") then roots[view.root] = true end
	end
	for root in pairs(roots) do jj.snapshot(root) end
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

--- Preview the change under the cursor. On a file: its side-by-side diff.
--- On a commit: every file in one buffer (split), or each file side by side
--- through a quickfix list (tab).
---@param in_tab boolean
function M.preview(in_tab)
	local view = views[vim.api.nvim_get_current_buf()]
	local item = view.items[vim.fn.line(".")]
	if not item or not item.commit then return end

	if item.kind == "file" then
		diff.open(view.root, item.commit, item.file, in_tab)
	elseif not in_tab then
		diff.open_show(view.root, item.commit)
	else
		load_files(view.root, { item.commit })
		local files = file_cache[item.commit.commit_id]
		if files then diff.open_files(view.root, item.commit, files) end
	end
end

-- Run a jj command that changes the repo. The log refreshes through its
-- watcher; buffers of files jj rewrote reload (with 'autoread').
local function exec(root, args)
	local ok, err = jj.exec(root, args)
	if not ok then
		vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
		return false
	end
	vim.cmd.checktime()
	return true
end

--- Make the commit under the cursor the working copy (`jj edit`).
function M.edit()
	local buf = vim.api.nvim_get_current_buf()
	local c = commit_at(buf, vim.fn.line("."))
	if c then exec(views[buf].root, { "edit", c.commit_id }) end
end

--- On a file line: edit its commit, then open the file for editing.
---@param in_tab boolean open in a new tab instead of a split
function M.open_file(in_tab)
	local view = views[vim.api.nvim_get_current_buf()]
	local item = view.items[vim.fn.line(".")]
	if not item or item.kind ~= "file" then return end
	if item.file.status == "D" then
		vim.notify("jumanji: " .. item.file.path .. " is deleted in this commit", vim.log.levels.WARN)
		return
	end

	if not exec(view.root, { "edit", item.commit.commit_id }) then return end
	local path = vim.fs.joinpath(view.root, item.file.path)
	vim.cmd((in_tab and "tabedit " or "belowright split ") .. vim.fn.fnameescape(path))
end

--- Toggle the selection of the commit under the cursor, then move to the
--- next commit.
function M.toggle_select()
	local buf = vim.api.nvim_get_current_buf()
	local view = views[buf]
	local lnum = vim.fn.line(".")
	local c = commit_at(buf, lnum)
	if not c then return end

	view.selected[c.change_id] = not view.selected[c.change_id] or nil
	render(buf)
	for i = lnum + 1, #view.items do
		if view.items[i].kind == "commit" then
			vim.cmd("normal! " .. i .. "G")
			return
		end
	end
end

--- Abandon the selected commits, or the one under the cursor, once confirmed.
function M.abandon()
	local buf = vim.api.nvim_get_current_buf()
	local view = views[buf]
	local targets = {}
	for _, item in ipairs(view.items) do
		if item.kind == "commit" and view.selected[item.commit.change_id] then targets[#targets + 1] = item.commit end
	end
	if #targets == 0 then targets = { commit_at(buf, vim.fn.line(".")) } end
	if #targets == 0 then return end

	local lines, ids = {}, {}
	for _, c in ipairs(targets) do
		lines[#lines + 1] = ("  %s %s"):format(c.change_id:sub(1, 8), c.description)
		ids[#ids + 1] = c.commit_id
	end
	local prompt = ("Abandon %d commit%s?\n%s"):format(#targets, #targets == 1 and "" or "s", table.concat(lines, "\n"))
	if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then return end

	if exec(view.root, vim.list_extend({ "abandon" }, ids)) then
		view.selected = {}
		render(buf)
	end
end

--- Move a local bookmark, picked from a list, to the commit under the cursor.
function M.set_bookmark()
	local view = views[vim.api.nvim_get_current_buf()]
	local c = commit_at(vim.api.nvim_get_current_buf(), vim.fn.line("."))
	if not c then return end

	local bookmarks, err = jj.bookmarks(view.root)
	if not bookmarks then
		vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
		return
	end
	local names = {}
	for _, b in ipairs(bookmarks) do
		if not b.remote then names[#names + 1] = b.name end
	end
	if #names == 0 then
		vim.notify("jumanji: no local bookmarks")
		return
	end

	vim.ui.select(names, { prompt = "Move bookmark to " .. c.change_id:sub(1, 8) }, function(name)
		if name then
			exec(view.root, { "bookmark", "set", name, "--allow-backwards", "-r", c.commit_id })
		end
	end)
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
		views[buf] = { root = root, revset = revset, rows = {}, items = {}, expanded = {}, selected = {} }
		watch.start(root, function() M.refresh_root(root) end)
		vim.api.nvim_create_autocmd("BufWinEnter", {
			buffer = buf,
			callback = function()
				if views[buf].stale then refresh(buf) end
			end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				views[buf] = nil
				watch.stop(root)
			end,
		})
	end

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "jumanji"
	refresh(buf)
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
