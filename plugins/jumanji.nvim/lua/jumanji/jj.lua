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

-- Run jj synchronously; returns the parsed stdout, or nil and jj's stderr.
local function run(root, cmd, parser)
	local obj = vim.system(cmd, { cwd = root, text = true }):wait()
	if obj.code ~= 0 then return nil, vim.trim(obj.stderr or "") end
	return parser(obj.stdout or "")
end

--- Run `jj log`; returns rows, or nil and an error.
---@param root string
---@param revset string?
---@return table? rows, string? err
function M.log(root, revset)
	local cmd = { "jj", "log", "--color=never", "--no-pager", "-T", TEMPLATE }
	if revset then
		vim.list_extend(cmd, { "-r", revset })
	end

	return run(root, cmd, parse)
end

-- Per commit: a record separator and its short id on one line, then one line
-- per changed file: status, source path, target path (repo-relative).
local FILES_TEMPLATE = [["\x1e" ++ commit_id.short(8) ++ "\n" ++ ]] ..
	[[self.diff().files().map(|f| f.status() ++ "\x1f" ++ f.source().path() ++ "\x1f" ++ f.path() ++ "\n").join("")]]

local STATUS_LETTER = { added = "A", removed = "D", modified = "M", renamed = "R", copied = "C" }

--- Parse FILES_TEMPLATE output into { [commit_id] = { { status, source, path } } }.
local function parse_files(stdout)
	local by_commit, files = {}, nil
	for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
		local id = line:match("^\x1e(.*)$")
		if id then
			files = {}
			by_commit[id] = files
		else
			local f = vim.split(line, "\x1f", { plain = true })
			files[#files + 1] = { status = STATUS_LETTER[f[1]] or "M", source = f[2], path = f[3] }
		end
	end
	return by_commit
end

--- List the files changed in each of the given commits, in one jj call.
---@param root string
---@param commit_ids string[] short (8-char) commit ids
---@return table? files_by_commit_id, string? err
function M.files(root, commit_ids)
	local cmd = {
		"jj", "log", "--ignore-working-copy", "--color=never", "--no-pager", "--no-graph",
		"-r", table.concat(commit_ids, " | "), "-T", FILES_TEMPLATE,
	}
	return run(root, cmd, parse_files)
end

--- A commit's header, message and whole change in git's diff format.
---@param root string
---@param rev string
---@return string? text, string? err
function M.show_git(root, rev)
	local cmd = { "jj", "show", "--git", "--ignore-working-copy", "--color=never", "--no-pager", "-r", rev }
	return run(root, cmd, function(out) return out end)
end

--- Change ids and local bookmark names in the default log revset, for completion.
---@param root string
---@return string[]
function M.refs(root)
	local cmd = {
		"jj", "log", "--ignore-working-copy", "--color=never", "--no-pager", "--no-graph",
		"-T", [[change_id.short(8) ++ "\n" ++ local_bookmarks.map(|b| b.name() ++ "\n").join("")]],
	}
	return run(root, cmd, function(out) return vim.split(out, "\n", { trimempty = true }) end) or {}
end

--- Annotate one line of a file, synchronously. On success, stdout holds the
--- line's change id, author, date and JSON-escaped message, unit-separated.
---@param root string
---@param rev string? defaults to @
---@param path string repo-relative
---@param lnum integer
---@return vim.SystemCompleted
function M.annotate_line(root, rev, path, lnum)
	local template = ([[if(line_number == %d, ]] ..
		[[commit.change_id().short(8) ++ "\x1f" ++ commit.author().name() ++ "\x1f" ++ ]] ..
		[[commit.author().timestamp().format("%%Y-%%m-%%d %%H:%%M") ++ "\x1f" ++ commit.description().escape_json())]]):format(lnum)
	local cmd = { "jj", "file", "annotate", "--no-pager", "-T", template, path }
	if rev then vim.list_extend(cmd, { "-r", rev }) end
	return vim.system(cmd, { cwd = root, text = true }):wait()
end

--- The repo's store directory. A secondary workspace's .jj/repo is a file
--- holding the path to the main workspace's store.
---@param root string
---@return string
function M.repo_dir(root)
	local path = vim.fs.joinpath(root, ".jj", "repo")
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.type ~= "file" then return path end

	local target = vim.trim(table.concat(vim.fn.readfile(path), "\n"))
	if not vim.startswith(target, "/") then target = vim.fs.joinpath(root, ".jj", target) end
	return vim.fs.normalize(target)
end

--- Snapshot the working copy in the background. Creates an operation only
--- when files changed, which the log watchers pick up.
---@param root string
function M.snapshot(root)
	vim.system({ "jj", "util", "snapshot" }, { cwd = root })
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
