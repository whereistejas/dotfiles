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
	-- JSON-escaped so a multi-line message stays on the commit's one line.
	"description.escape_json()",
}
local TEMPLATE = [["\x1e" ++ ]] .. table.concat(FIELDS, [[ ++ "\x1f" ++ ]]) .. [[ ++ "\n"]]

local function parse_commit(record)
	local f = vim.split(record, "\x1f", { plain = true })
	local message = vim.trim(vim.json.decode(f[12]))
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
		description = message:match("^[^\n]*"),
		message = message == "" and {} or vim.split(message, "\n", { plain = true }),
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

local function run(root, cmd, parser, on_done)
	vim.system(cmd, { cwd = root, text = true }, vim.schedule_wrap(function(obj)
		if obj.code ~= 0 then
			on_done(nil, vim.trim(obj.stderr or ""))
		else
			on_done(parser(obj.stdout or ""))
		end
	end))
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

	run(root, cmd, parse, on_done)
end

-- One line per changed file: status, source path, target path (repo-relative).
local FILES_TEMPLATE = [[self.diff().files().map(|f| f.status() ++ "\x1f" ++ f.source().path() ++ "\x1f" ++ f.path() ++ "\n").join("")]]

local STATUS_LETTER = { added = "A", removed = "D", modified = "M", renamed = "R", copied = "C" }

--- Parse FILES_TEMPLATE output into { status = string, source = string, path = string }.
local function parse_files(stdout)
	local files = {}
	for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
		local f = vim.split(line, "\x1f", { plain = true })
		files[#files + 1] = { status = STATUS_LETTER[f[1]] or "M", source = f[2], path = f[3] }
	end
	return files
end

--- List the files changed in a commit. `on_done(files, err)` runs on the main loop.
---@param root string
---@param commit_id string
---@param on_done fun(files: table?, err: string?)
function M.files(root, commit_id, on_done)
	local cmd = {
		"jj", "log", "--ignore-working-copy", "--color=never", "--no-pager", "--no-graph",
		"-r", commit_id, "-T", FILES_TEMPLATE,
	}
	run(root, cmd, parse_files, on_done)
end

--- Read a file's content at a revision, synchronously.
---@param root string
---@param rev string
---@param path string repo-relative
---@return vim.SystemCompleted
function M.file_show(root, rev, path)
	local fileset = "root-file:" .. vim.json.encode(path)
	local cmd = { "jj", "file", "show", "--ignore-working-copy", "--no-pager", "-r", rev, fileset }
	return vim.system(cmd, { cwd = root, text = true }):wait()
end

return M
