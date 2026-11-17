local diff = require("jumanji.diff")
local jj = require("jumanji.jj")

local M = {}

-- The repo root, revision and repo-relative path of the current buffer; the
-- revision is nil (jj's default, @) for files on disk.
local function target()
	local name = vim.api.nvim_buf_get_name(0)
	local root, rev, path = diff.parse_url(name)
	if root then return root, rev, path end

	root = vim.fs.root(0, ".jj")
	if not root or name == "" then return end
	return root, nil, vim.fs.relpath(root, name)
end

--- Show the change that last touched the cursor line in a float. Calling it
--- again while the float is open focuses the float.
function M.line()
	local root, rev, path = target()
	if not path then
		vim.notify("jumanji: not a file in a jj repo", vim.log.levels.ERROR)
		return
	end

	local obj = jj.annotate_line(root, rev, path, vim.fn.line("."))
	if obj.code ~= 0 then
		vim.notify("jumanji: " .. vim.trim(obj.stderr or ""), vim.log.levels.ERROR)
		return
	end
	if (obj.stdout or "") == "" then
		vim.notify("jumanji: no annotation for this line (unsaved?)", vim.log.levels.WARN)
		return
	end

	local f = vim.split(obj.stdout, "\x1f", { plain = true })
	local header = ("%s  %s  %s"):format(f[1], f[2], f[3])
	local lines = { header }
	local message = vim.trim(vim.json.decode(f[4]))
	if message ~= "" then
		lines[#lines + 1] = ""
		vim.list_extend(lines, vim.split(message, "\n", { plain = true }))
	end

	local buf = vim.lsp.util.open_floating_preview(lines, "", { focus_id = "jumanji_annotate" })
	local ns = vim.api.nvim_create_namespace("jumanji_annotate")
	local author_col = #f[1] + 2
	local date_col = author_col + #f[2] + 2
	vim.hl.range(buf, ns, "JumanjiChangeIdPrefix", { 0, 0 }, { 0, #f[1] })
	vim.hl.range(buf, ns, "JumanjiAuthor", { 0, author_col }, { 0, author_col + #f[2] })
	vim.hl.range(buf, ns, "JumanjiTimestamp", { 0, date_col }, { 0, #header })
end

return M
