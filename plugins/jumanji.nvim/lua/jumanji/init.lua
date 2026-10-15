local diff = require("jumanji.diff")
local jj = require("jumanji.jj")
local watch = require("jumanji.watch")

local M = {}

local ns = vim.api.nvim_create_namespace("jumanji")
local block_ns = vim.api.nvim_create_namespace("jumanji-block")

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

	for _, name in ipairs(c.workspaces) do
		push(name .. "@", "JumanjiWorkspace")
		push(" ")
	end
	if c.bookmarks ~= "" then
		push(c.bookmarks, "JumanjiBookmark")
		push(" ")
	end
	push(c.author, "JumanjiAuthor")
	push(" ")
	push(c.timestamp, "JumanjiTimestamp")
	push(" ")
	push(c.commit_id, "JumanjiCommitId")
	if c.conflict then push(" (conflict)", "JumanjiConflict") end
end

local function render_description(push, graph, c)
	push(graph, "JumanjiGraph")
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

-- The message after its first line, which the description row shows.
local function message_body(message)
	local body = vim.list_slice(message, 2)
	while body[1] == "" do table.remove(body, 1) end
	return body
end

-- Display items, one per buffer line: jj's rows plus, under each expanded
-- commit's description row, the rest of its message and its changed files.
local function build_items(view)
	local items = {}
	for _, row in ipairs(view.rows) do
		local c = row.commit
		items[#items + 1] = { kind = row.kind, graph = row.graph, commit = c }

		local files = row.kind == "description" and view.expanded[c.change_id] and file_cache[c.commit_id]
		if files then
			local graph = row.graph
			local body = message_body(c.message)
			for _, text in ipairs(body) do
				items[#items + 1] = { kind = "message", graph = graph, commit = c, text = text }
			end
			if #body > 0 and #files > 0 then
				items[#items + 1] = { kind = "message", graph = graph, commit = c, text = "" }
			end
			for _, file in ipairs(files) do
				items[#items + 1] = { kind = "file", graph = graph, commit = c, file = file }
			end
		end
	end
	return items
end

-- Highlight every line of the commit under the cursor: its two rows and, when
-- expanded, its message and files.
local function highlight_block(buf)
	local view = views[buf]
	vim.api.nvim_buf_clear_namespace(buf, block_ns, 0, -1)

	local win = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win() or vim.fn.win_findbuf(buf)[1]
	if not win then return end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local c = view.items[lnum] and view.items[lnum].commit
	if not c then return end

	local first, last = lnum, lnum
	while view.items[first - 1] and view.items[first - 1].commit == c do first = first - 1 end
	while view.items[last + 1] and view.items[last + 1].commit == c do last = last + 1 end
	for i = first, last do
		vim.api.nvim_buf_set_extmark(buf, block_ns, i - 1, 0, { line_hl_group = "JumanjiCursorBlock" })
	end
end

local function render(buf)
	local view = views[buf]
	view.items = build_items(view)

	local lines, line_marks = {}, {}
	for i, item in ipairs(view.items) do
		local push, finish = line_builder()
		if item.kind == "commit" then
			render_commit(push, item.graph, item.commit)
		elseif item.kind == "description" then
			render_description(push, item.graph, item.commit)
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
		local item = view.items[i]
		if item.kind == "commit" and view.selected[item.commit.change_id] then
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { sign_text = "\u{25cf}", sign_hl_group = "JumanjiSelected" })
		end
	end
	highlight_block(buf)
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
		if row.kind == "commit" and view.expanded[row.commit.change_id] then
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
	highlight_block(buf)
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
			highlight_block(buf)
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

--- Start a new working-copy commit on top of the commit under the cursor
--- (`jj new`).
function M.new()
	local buf = vim.api.nvim_get_current_buf()
	local c = commit_at(buf, vim.fn.line("."))
	if c then exec(views[buf].root, { "new", c.commit_id }) end
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
			highlight_block(buf)
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

-- Real paths, so a symlink (like macOS's /tmp) can lead to either side.
local function same_dir(a, b)
	return (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

-- Forget a workspace in the background and, given its directory, then delete that.
local function forget_workspace(root, name, dir)
	jj.exec_async(root, { "workspace", "forget", name }, function(_, err)
		if err then
			vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
			return
		end
		if not dir then return end

		vim.system({ "rm", "-rf", "--", dir }, {}, vim.schedule_wrap(function(obj)
			if obj.code ~= 0 then
				vim.notify("jumanji: forgot " .. name .. ", but couldn't delete " .. dir, vim.log.levels.ERROR)
				return
			end
			vim.notify("jumanji: deleted " .. dir)
		end))
	end)
end

--- Pick a workspace whose working copy is the commit under the cursor, then
--- whether to forget it or also delete its directory. jj and the deletion run
--- in the background.
function M.workspace_actions()
	local buf = vim.api.nvim_get_current_buf()
	local view = views[buf]
	local c = commit_at(buf, vim.fn.line("."))
	if not c or #c.workspaces == 0 then
		vim.notify("jumanji: not a workspace's working copy")
		return
	end

	local function act(name, dir)
		if dir and same_dir(dir, view.root) then
			vim.notify("jumanji: " .. name .. " is the workspace this log is in", vim.log.levels.ERROR)
			return
		end

		-- The directory that holds the repo's store can't go: every workspace needs it.
		local deletable = dir and vim.fn.isdirectory(vim.fs.joinpath(dir, ".jj", "repo")) == 0
		local actions = { { label = "Forget, keep its files" .. (dir and (" in " .. dir) or "") } }
		if deletable then actions[2] = { label = "Forget and delete " .. dir, delete = true } end

		vim.ui.select(actions, {
			prompt = "Workspace " .. name,
			format_item = function(a) return a.label end,
		}, function(action)
			if not action then return end
			if action.delete and vim.fn.confirm(("Delete %s?"):format(dir), "&Yes\n&No", 2) ~= 1 then return end

			forget_workspace(view.root, name, action.delete and dir or nil)
		end)
	end

	jj.workspaces(view.root, function(workspaces, err)
		if not workspaces then
			vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
			return
		end
		local roots = {}
		for _, w in ipairs(workspaces) do roots[w.name] = w.root end

		if #c.workspaces == 1 then
			act(c.workspaces[1], roots[c.workspaces[1]])
			return
		end
		vim.ui.select(c.workspaces, { prompt = "Workspace" }, function(name)
			if name then act(name, roots[name]) end
		end)
	end)
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
		watch.start(root, M.refresh_root)
		vim.api.nvim_create_autocmd("BufWinEnter", {
			buffer = buf,
			callback = function()
				if views[buf].stale then refresh(buf) end
			end,
		})
		vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = buf,
			callback = function() highlight_block(buf) end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				views[buf] = nil
				watch.stop(root, M.refresh_root)
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
---@param root string? defaults to the current log's repo, or the current file's
function M.open(revset, root)
	local current = views[vim.api.nvim_get_current_buf()]
	root = root or current and current.root or vim.fs.root(0, ".jj") or vim.fs.root(vim.fn.getcwd(), ".jj")
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
