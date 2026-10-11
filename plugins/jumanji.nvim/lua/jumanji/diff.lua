local jj = require("jumanji.jj")

local M = {}

-- File contents at a revision live at jumanji://<root>//<rev>/<path>, read by
-- the BufReadCmd autocmd in plugin/jumanji.lua (root is absolute, so the URL
-- starts with "jumanji:///").
local function url(root, rev, path)
	return ("jumanji://%s//%s/%s"):format(root, rev, path)
end

--- BufReadCmd handler: fill the buffer with the file's content at the revision.
---@param buf integer
function M.read(buf)
	local root, rev, path = vim.api.nvim_buf_get_name(buf):match("^jumanji://(.-)//([^/]+)/(.+)$")
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
