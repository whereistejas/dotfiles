local jj = require("jumanji.jj")

local M = {}

local ns = vim.api.nvim_create_namespace("jumanji-diff")

-- File contents at a revision live at jumanji://<root>//<rev>/<path>, read by
-- the BufReadCmd autocmd in plugin/jumanji.lua (root is absolute, so the URL
-- starts with "jumanji:///").
local function url(root, rev, path)
	return ("jumanji://%s//%s/%s"):format(root, rev, path)
end

--- Split a jumanji:// file URL into its parts; nil for any other name.
---@param name string
---@return string? root, string? rev, string? path
function M.parse_url(name)
	return name:match("^jumanji://(/.-)//([^/]+)/(.+)$")
end

--- BufReadCmd handler: fill the buffer with the file's content at the revision.
---@param buf integer
function M.read(buf)
	local root, rev, path = M.parse_url(vim.api.nvim_buf_get_name(buf))
	if not root then return end

	local obj = jj.file_show(root, rev, path)

	-- A path missing at the revision (added or deleted file) reads as empty.
	local text = obj.stdout or ""
	if obj.code ~= 0 and not (obj.stderr or ""):find("No such path", 1, true) then
		vim.notify("jumanji: " .. vim.trim(obj.stderr or ""), vim.log.levels.ERROR)
	end

	local lines = vim.split(text, "\n", { plain = true })
	if lines[#lines] == "" then table.remove(lines) end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ""
end

-- A commit's whole change lives at jumanji://show<root>//<commit_id>.
local function show_url(root, commit_id)
	return ("jumanji://show%s//%s"):format(root, commit_id)
end

-- Draw a git-format diff of any number of files: with snacks' diff renderer
-- (syntax per file, line numbers) when it's available, else as plain text
-- with Neovim's diff syntax.
local function render(buf, text)
	vim.bo[buf].modifiable = true
	local ok, snacks_diff = pcall(require, "snacks.picker.util.diff")
	if not (ok and pcall(snacks_diff.render, buf, ns, text)) then
		local lines = vim.split(text, "\n", { plain = true })
		if lines[#lines] == "" then table.remove(lines) end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].filetype = "diff"
	end
	vim.bo[buf].modifiable = false
end

--- BufReadCmd handler for a commit's whole change.
---@param buf integer
function M.read_show(buf)
	local root, rev = vim.api.nvim_buf_get_name(buf):match("^jumanji://show(/.-)//(.+)$")
	if not root then return end

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false

	local text, err = jj.show_git(root, rev)
	if not text then
		vim.notify("jumanji: " .. err, vim.log.levels.ERROR)
		return
	end
	render(buf, text)
end

--- Open a commit's whole change, every file in one buffer, in a split.
---@param root string
---@param commit table
function M.open_show(root, commit)
	vim.cmd("belowright split " .. vim.fn.fnameescape(show_url(root, commit.commit_id)))
end

-- Diffs opened from a quickfix list of a commit's files: an entry's
-- user_data.jumanji_before is the URL of the file before the change.
local function current_qf_before(buf)
	local idx = vim.fn.getqflist({ idx = 0 }).idx
	local entry = vim.fn.getqflist({ idx = idx, items = 1 }).items[1]
	if not entry or entry.bufnr ~= buf or type(entry.user_data) ~= "table" then return nil end
	return entry.user_data.jumanji_before
end

local pairing = false

--- BufWinEnter handler for file URLs: when the buffer is the current entry of
--- a commit's quickfix list (see open_files), pair it with the file before the
--- change, in diff mode, in the tab's other window.
---@param buf integer
function M.on_win_enter(buf)
	local before = not pairing and current_qf_before(buf)
	if not before then return end

	-- Quickfix entries need their buffer to outlive its window.
	vim.bo[buf].bufhidden = "hide"

	pairing = true
	local win = vim.api.nvim_get_current_win()
	local other
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if w ~= win and vim.fn.win_gettype(w) == "" then other = w end
	end

	-- A quickfix jump from the left (before) window lands in it: move the
	-- file to the right one so the sides stay put.
	local after_win, before_win = win, other
	if other and vim.w[win].jumanji_before then
		after_win, before_win = other, win
		vim.api.nvim_win_set_buf(after_win, buf)
	end

	vim.cmd("diffoff!")
	if before_win then
		vim.api.nvim_win_call(before_win, function() vim.cmd.edit(vim.fn.fnameescape(before)) end)
	else
		vim.api.nvim_win_call(after_win, function()
			vim.cmd("leftabove vertical split " .. vim.fn.fnameescape(before))
			before_win = vim.api.nvim_get_current_win()
		end)
	end
	vim.w[before_win].jumanji_before = true
	vim.w[after_win].jumanji_before = nil
	vim.api.nvim_win_call(before_win, vim.cmd.diffthis)
	vim.api.nvim_win_call(after_win, vim.cmd.diffthis)
	vim.api.nvim_set_current_win(after_win)
	pairing = false
end

--- Open every file of a commit's change as a side-by-side diff, one at a time,
--- in a new tab: the files are a quickfix list, ]q and [q step through them.
---@param root string
---@param commit table
---@param files table[] { status, source, path }
function M.open_files(root, commit, files)
	if #files == 0 then
		vim.notify("jumanji: no changes in " .. commit.change_id:sub(1, 8))
		return
	end

	local items = {}
	for _, file in ipairs(files) do
		local renamed = file.source ~= file.path and (file.source .. " \u{2192} ") or ""
		items[#items + 1] = {
			filename = url(root, commit.commit_id, file.path),
			text = file.status .. " " .. renamed .. file.path,
			user_data = { jumanji_before = url(root, commit.commit_id .. "-", file.source) },
		}
	end

	vim.cmd.tabnew()
	vim.fn.setqflist({}, " ", {
		title = ("%s %s"):format(commit.change_id:sub(1, 8), commit.description),
		items = items,
		quickfixtextfunc = function(info)
			local entries = vim.fn.getqflist({ id = info.id, items = 1 }).items
			local out = {}
			for i = info.start_idx, info.end_idx do out[#out + 1] = entries[i].text end
			return out
		end,
	})
	vim.cmd("botright copen")
	vim.cmd.wincmd("p")
	vim.cmd.cfirst()
end

--- Open a commit's change to one file as a side-by-side diff.
---@param root string
---@param commit table
---@param file table { status, source, path }
---@param in_tab boolean open in a new tab instead of a split
function M.open(root, commit, file, in_tab)
	local after = url(root, commit.commit_id, file.path)
	local before = url(root, commit.commit_id .. "-", file.source)

	vim.cmd((in_tab and "tabedit " or "belowright split ") .. vim.fn.fnameescape(after))
	vim.cmd("leftabove vertical diffsplit " .. vim.fn.fnameescape(before))
	vim.cmd.wincmd("p")
end

return M
