local M = {}

-- Two lines per commit. The first: a record separator marks where jj's graph
-- prefix ends, then the fields, joined by a unit separator. The second is a
-- group separator alone, so jj draws the graph prefix of the commit's second
-- row.
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
	-- Workspaces whose working copy this is; empty while the repo has just one.
	[[working_copies.map(|w| w.name()).join(" ")]],
}
local TEMPLATE = [["\x1e" ++ ]] .. table.concat(FIELDS, [[ ++ "\x1f" ++ ]]) .. [[ ++ "\n\x1d\n"]]

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
		workspaces = vim.split(f[13], " ", { trimempty = true }),
	}
end

--- Parse `jj log` output into rows of { kind = string, graph = string, commit = table? }.
--- A commit has a "commit" row then a "description" row; "graph" rows are
--- graph-only lines (edges, elisions).
local function parse(stdout)
	local rows, commit = {}, nil
	for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
		local graph, record = line:match("^(.-)\x1e(.*)$")
		local second = line:match("^(.-)\x1d$")
		if graph then
			commit = parse_commit(record)
			rows[#rows + 1] = { kind = "commit", graph = graph, commit = commit }
		elseif second and commit then
			rows[#rows + 1] = { kind = "description", graph = second, commit = commit }
		else
			rows[#rows + 1] = { kind = "graph", graph = line }
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

--- Whether jj failed because the working copy is stale, which
--- `jj workspace update-stale` fixes.
---@param err string jj's stderr
---@return boolean
function M.is_stale(err)
	return err:find("working copy is stale", 1, true) ~= nil
end

--- Run a jj command that changes the repo; returns nil and jj's stderr on failure.
---@param root string
---@param args string[]
---@return true? ok, string? err
function M.exec(root, args)
	return run(root, vim.list_extend({ "jj", "--no-pager" }, args), function() return true end)
end

local BOOKMARK_TEMPLATE = table.concat({
	"name", "remote", [[if(synced, "1")]], [[if(conflict, "1")]],
	[[if(normal_target, normal_target.change_id().short(8))]],
	[[if(normal_target, normal_target.description().first_line())]],
	[[if(normal_target, normal_target.commit_id().short(8))]],
}, [[ ++ "\x1f" ++ ]]) .. [[ ++ "\n"]]

--- Local and remote bookmarks. A remote bookmark synced with its local one,
--- and the git remote that mirrors the backing repo, are left out.
---@param root string
---@return table[]? bookmarks { name, remote?, conflict, change_id?, description?, commit_id? }, string? err
function M.bookmarks(root)
	local cmd = {
		"jj", "bookmark", "list", "--all-remotes", "--ignore-working-copy", "--color=never", "--no-pager",
		"-T", BOOKMARK_TEMPLATE,
	}
	return run(root, cmd, function(out)
		local list = {}
		for line in vim.gsplit(out, "\n", { plain = true, trimempty = true }) do
			local f = vim.split(line, "\x1f", { plain = true })
			local remote = f[2] ~= "" and f[2] or nil
			if not (remote and (remote == "git" or f[3] == "1")) then
				list[#list + 1] = {
					name = f[1],
					remote = remote,
					conflict = f[4] == "1",
					change_id = f[5] ~= "" and f[5] or nil,
					description = f[6],
					commit_id = f[7] ~= "" and f[7] or nil,
				}
			end
		end
		return list
	end)
end

local PARENTS_TEMPLATE = [[commit_id.short(8) ++ "\x1f" ++ if(self.contained_in("trunk()"), "1") ++ "\x1f" ++ ]] ..
	[[parents.map(|c| c.commit_id().short(8)).join(" ") ++ "\n"]]

--- The parents of each commit in a revset, by short (8-char) commit id, and
--- which of them is trunk().
---@param root string
---@param revset string
---@return { trunk: string?, parents: table<string, string[]> }? graph, string? err
function M.parents(root, revset)
	local cmd = {
		"jj", "log", "--ignore-working-copy", "--color=never", "--no-pager", "--no-graph",
		"-r", revset, "-T", PARENTS_TEMPLATE,
	}
	return run(root, cmd, function(out)
		local graph = { parents = {} }
		for line in vim.gsplit(out, "\n", { plain = true, trimempty = true }) do
			local f = vim.split(line, "\x1f", { plain = true })
			graph.parents[f[1]] = vim.split(f[3], " ", { trimempty = true })
			if f[2] == "1" then graph.trunk = f[1] end
		end
		return graph
	end)
end

-- Run jj in the background. `on_done` runs on the main loop with the parsed
-- stdout, or nil and jj's stderr.
local function run_async(root, cmd, parser, on_done)
	vim.system(cmd, { cwd = root, text = true }, function(obj)
		vim.schedule(function()
			if obj.code ~= 0 then
				on_done(nil, vim.trim(obj.stderr or ""))
				return
			end
			on_done(parser(obj.stdout or ""))
		end)
	end)
end

--- Run a jj command that changes the repo, in the background.
---@param root string
---@param args string[]
---@param on_done fun(ok: true?, err: string?)
function M.exec_async(root, args, on_done)
	run_async(root, vim.list_extend({ "jj", "--no-pager" }, args), function() return true end, on_done)
end

--- List the repo's workspaces in the background. `root` is nil for a
--- workspace jj has no path for.
---@param root string
---@param on_done fun(workspaces: { name: string, root: string? }[]?, err: string?)
function M.workspaces(root, on_done)
	local cmd = {
		"jj", "workspace", "list", "--ignore-working-copy", "--color=never", "--no-pager",
		"-T", [[name ++ "\x1f" ++ root ++ "\n"]],
	}
	run_async(root, cmd, function(out)
		local list = {}
		for line in vim.gsplit(out, "\n", { plain = true, trimempty = true }) do
			local f = vim.split(line, "\x1f", { plain = true })
			list[#list + 1] = { name = f[1], root = f[2] ~= "" and f[2] or nil }
		end
		return list
	end, on_done)
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

-- The working copy's workspace, unless it's the default one, and its change id.
local WORKING_COPY_TEMPLATE = [[working_copies.filter(|w| w.name() != "default").map(|w| w.name()).join(" ")]] ..
	[[ ++ "\x1f" ++ change_id.short(8)]]

--- Read the working copy in the background, without snapshotting it.
--- `on_done` runs on the main loop, and only if jj succeeds.
---@param root string
---@param on_done fun(wc: { workspace: string?, change_id: string })
function M.working_copy(root, on_done)
	local cmd = {
		"jj", "log", "--ignore-working-copy", "--color=never", "--no-pager", "--no-graph",
		"-r", "@", "-T", WORKING_COPY_TEMPLATE,
	}
	vim.system(cmd, { cwd = root, text = true }, function(obj)
		if obj.code ~= 0 then return end

		local f = vim.split(obj.stdout or "", "\x1f", { plain = true })
		vim.schedule(function()
			on_done({ workspace = f[1] ~= "" and f[1] or nil, change_id = f[2] })
		end)
	end)
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
