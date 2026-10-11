local M = {}

-- One record per commit: a record separator marks where jj's graph prefix ends,
-- then the fields, joined by a unit separator.
local FIELDS = {
	"change_id.short(12)",
	"change_id.shortest(1).prefix()",
	"commit_id.short(8)",
	[[if(current_working_copy, "1")]],
	[[if(immutable, "1")]],
	[[if(conflict, "1")]],
	[[if(empty, "1")]],
	[[if(divergent, "1")]],
	[[bookmarks.join(" ")]],
	"author.email().local()",
	"committer.timestamp().ago()",
	"description.first_line()",
}
local TEMPLATE = [["\x1e" ++ ]] .. table.concat(FIELDS, [[ ++ "\x1f" ++ ]]) .. [[ ++ "\n"]]

local function parse_commit(record)
	local f = vim.split(record, "\x1f", { plain = true })
	return {
		change_id = f[1],
		prefix = f[2],
		commit_id = f[3],
		working_copy = f[4] == "1",
		immutable = f[5] == "1",
		conflict = f[6] == "1",
		empty = f[7] == "1",
		divergent = f[8] == "1",
		bookmarks = f[9],
		author = f[10],
		timestamp = f[11],
		description = f[12],
	}
end

--- Parse `jj log` output into rows of { graph = string, commit = table? }.
--- Rows without a commit are graph-only lines (edges, elisions).
local function parse(stdout)
	local rows = {}
	for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
		local graph, record = line:match("^(.-)\x1e(.*)$")
		if graph then
			rows[#rows + 1] = { graph = graph, commit = parse_commit(record) }
		else
			rows[#rows + 1] = { graph = line }
		end
	end
	return rows
end

--- Run `jj log` asynchronously. `on_done(rows, err)` is called on the main loop.
---@param root string
---@param revset string?
---@param on_done fun(rows: table?, err: string?)
function M.log(root, revset, on_done)
	local cmd = { "jj", "log", "--color=never", "--no-pager", "-T", TEMPLATE }
	if revset then
		vim.list_extend(cmd, { "-r", revset })
	end

	vim.system(cmd, { cwd = root, text = true }, vim.schedule_wrap(function(obj)
		if obj.code ~= 0 then
			on_done(nil, vim.trim(obj.stderr or ""))
		else
			on_done(parse(obj.stdout or ""))
		end
	end))
end

return M
