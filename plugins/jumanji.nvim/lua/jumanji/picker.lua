local jj = require("jumanji.jj")
local mr = require("jumanji.mr")

local M = {}

-- The repo of the buffer the picker opens from, read before the picker's own
-- windows take focus.
local function with_root(opts)
	opts.jj_root = opts.jj_root or vim.fs.root(0, ".jj") or vim.fs.root(vim.fn.getcwd(), ".jj")
	return opts
end

local function fail(err)
	vim.notify("jumanji: " .. (err or "not inside a jj repo"), vim.log.levels.ERROR)
	return {}
end

-- A bookmark as a revset symbol, quoted so any name parses.
local function symbol(b)
	local name = vim.json.encode(b.name)
	return b.remote and (name .. "@" .. vim.json.encode(b.remote)) or name
end

local function bookmark_label(b)
	return b.remote and (b.name .. "@" .. b.remote) or b.name
end

-- The stack a commit is on: from trunk up to the commit and everything
-- stacked on it, with the 10 commits up to where it forked for context.
local function stack_revset(rev)
	return ("trunk()..(%s::) | ancestors(fork_point(trunk() | %s), 10)"):format(rev, rev)
end

-- Bookmarks grouped by the commit they point to, in the order jj lists them.
-- A conflicted bookmark points to no one commit and gets a node of its own.
local function bookmark_nodes(bookmarks)
	local nodes, by_rev = {}, {}
	for _, b in ipairs(bookmarks) do
		local rev = b.commit_id or symbol(b)
		if not by_rev[rev] then
			by_rev[rev] = { rev = rev, commit = b, bookmarks = {}, children = {} }
			nodes[#nodes + 1] = by_rev[rev]
		end
		table.insert(by_rev[rev].bookmarks, b)
	end
	return nodes, by_rev
end

local TRUNK = {}

-- Where a bookmarked commit's own commits start: the node of its nearest
-- bookmarked ancestor, or TRUNK once the walk leaves the stacks for trunk's
-- history. Nil for trunk, and for a commit that isn't on a stack.
local function fork_base(rev, graph, by_rev)
	if rev == graph.trunk or not graph.parents[rev] then return nil end

	local queue, seen = vim.list_extend({}, graph.parents[rev]), {}
	while #queue > 0 do
		local id = table.remove(queue, 1)
		if by_rev[id] then return by_rev[id] end
		if not graph.parents[id] then return TRUNK end
		if not seen[id] then
			seen[id] = true
			vim.list_extend(queue, graph.parents[id])
		end
	end
end

-- Bookmarks as a tree: trunk's bookmarks at the root, each stack a branch of
-- it, and a bookmark stacked on another a child of that one. Bookmarks that
-- aren't on a stack (merged, or off unrelated history) are roots of their own.
local function bookmark_items(opts)
	if not opts.jj_root then return fail() end
	local bookmarks, err = jj.bookmarks(opts.jj_root)
	if not bookmarks then return fail(err) end

	local nodes, by_rev = bookmark_nodes(bookmarks)
	local ids = { "none()" }
	for _, b in ipairs(bookmarks) do ids[#ids + 1] = b.commit_id end
	local graph, graph_err = jj.parents(opts.jj_root, ("trunk() | trunk()..(%s)"):format(table.concat(ids, " | ")))
	if not graph then return fail(graph_err) end

	local trunk = by_rev[graph.trunk]
	local roots = { trunk }
	for _, node in ipairs(nodes) do
		local base = fork_base(node.rev, graph, by_rev)
		node.base = base == TRUNK and "trunk()" or base and base.rev
		local parent = base == TRUNK and trunk or base
		if parent then
			table.insert(parent.children, node)
		elseif node ~= trunk then
			roots[#roots + 1] = node
		end
	end

	local items, width = {}, 0
	local function add(node, parent, last, depth)
		local label = table.concat(vim.tbl_map(bookmark_label, node.bookmarks), " ")
		local item = {
			text = label .. " " .. (node.commit.description or ""),
			label = label,
			node = node,
			root = opts.jj_root,
			parent = parent,
			last = last,
			width = 2 * depth + vim.fn.strdisplaywidth(label),
			revset = stack_revset(node.rev),
			preview = node.base and ("%s..%s"):format(node.base, node.rev) or ("ancestors(%s, 10)"):format(node.rev),
		}
		items[#items + 1] = item
		width = math.max(width, item.width)
		for i, child in ipairs(node.children) do add(child, item, i == #node.children, depth + 1) end
	end
	for i, node in ipairs(roots) do add(node, nil, i == #roots, 0) end

	for _, item in ipairs(items) do item.pad = string.rep(" ", width - item.width) end
	return items
end

local function format_bookmark(item, picker)
	local node = item.node
	local ret = Snacks.picker.format.tree(item, picker)
	for i, b in ipairs(node.bookmarks) do
		if i > 1 then ret[#ret + 1] = { " " } end
		ret[#ret + 1] = { bookmark_label(b), b.remote and "JumanjiDim" or "JumanjiBookmark" }
	end
	ret[#ret + 1] = { item.pad .. " " }

	local c = node.commit
	if c.conflict then ret[#ret + 1] = { "(conflict) ", "JumanjiConflict" } end
	if c.change_id then
		ret[#ret + 1] = { c.change_id, "JumanjiChangeId" }
		ret[#ret + 1] = { " " }
	end
	local mrs = mr.get(item.root)
	for _, b in ipairs(node.bookmarks) do
		if not b.remote and mrs[b.name] then
			ret[#ret + 1] = { "!" .. mrs[b.name], "JumanjiMergeRequest" }
			ret[#ret + 1] = { " " }
		end
	end
	ret[#ret + 1] = { c.description ~= "" and c.description or "(no description set)", c.description == "" and "JumanjiDim" or nil }
	return ret
end

local function log_items(opts)
	if not opts.jj_root then return fail() end
	local rows, err = jj.log(opts.jj_root, opts.revset)
	if not rows then return fail(err) end

	local items = {}
	for _, row in ipairs(rows) do
		local c = row.commit
		if row.kind == "commit" then
			items[#items + 1] = {
				text = table.concat({ c.change_id, c.bookmarks, c.description, c.author }, " "),
				commit = c,
				root = opts.jj_root,
			}
		end
	end
	return items
end

local function format_commit(item)
	local c = item.commit
	local ret = {
		{ c.working_copy and "@ " or "  ", "JumanjiWorkingCopy" },
		{ c.prefix, "JumanjiChangeIdPrefix" },
		{ c.change_id:sub(#c.prefix + 1, 8), "JumanjiChangeId" },
		{ " " },
	}
	if c.bookmarks ~= "" then
		ret[#ret + 1] = { c.bookmarks, "JumanjiBookmark" }
		ret[#ret + 1] = { " " }
	end
	if c.conflict then ret[#ret + 1] = { "(conflict) ", "JumanjiConflict" } end
	if c.empty then ret[#ret + 1] = { "(empty) ", "JumanjiDim" } end
	ret[#ret + 1] = c.description == "" and { "(no description set)", "JumanjiDim" } or { c.description }
	ret[#ret + 1] = { " " .. c.author .. " " .. c.timestamp, "JumanjiDim" }
	return ret
end

-- The commit's message and change, drawn like snacks' other diff previews.
local function preview_commit(ctx)
	local item = ctx.item
	if not item.diff then
		local text, err = jj.show_git(item.root, item.commit.commit_id)
		if not text then
			ctx.preview:notify(err, "error")
			return
		end
		item.diff = text
	end
	return Snacks.picker.preview.diff(ctx)
end

local function preview_branch(ctx)
	local cmd = { "jj", "log", "--color=always", "--no-pager", "--ignore-working-copy", "-r", ctx.item.preview }
	return Snacks.picker.preview.cmd(cmd, ctx, { cwd = ctx.item.root })
end

M.sources = {
	--- Bookmarks, local and remote, as a tree of stacks, with the numbers of
	--- your open GitLab MRs. The preview shows a bookmark's own commits;
	--- confirm opens the log of its whole stack.
	jj_bookmarks = {
		title = "jj bookmarks",
		config = with_root,
		finder = bookmark_items,
		format = format_bookmark,
		matcher = { keep_parents = true, sort = false },
		on_show = function(picker)
			if not picker.opts.jj_root then return end
			mr.fetch(picker.opts.jj_root, function()
				if not picker.closed then picker.list:update({ force = true }) end
			end)
		end,
		preview = preview_branch,
		confirm = function(picker, item)
			picker:close()
			if item then require("jumanji").open(item.revset, item.root) end
		end,
	},
	--- Commits in a revset (`revset` option, default jj's `revsets.log`).
	--- Confirm shows the commit's whole change.
	jj_log = {
		title = "jj log",
		config = with_root,
		finder = log_items,
		format = format_commit,
		preview = preview_commit,
		confirm = function(picker, item)
			picker:close()
			if item then require("jumanji.diff").open_show(item.root, item.commit) end
		end,
	},
}

--- Add the sources to snacks' picker sources: Snacks.picker.jj_bookmarks()
--- and Snacks.picker.jj_log().
---@param sources table snacks.picker.config.sources
function M.register(sources)
	for name, source in pairs(M.sources) do
		sources[name] = sources[name] or source
	end
end

return M
