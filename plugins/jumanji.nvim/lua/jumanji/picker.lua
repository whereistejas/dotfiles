local jj = require("jumanji.jj")

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

local function pad(text, width)
	return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
end

-- A bookmark as a revset symbol, quoted so any name parses.
local function symbol(b)
	local name = vim.json.encode(b.name)
	return b.remote and (name .. "@" .. vim.json.encode(b.remote)) or name
end

-- The commits on a bookmark's branch, with the 10 commits up to where it
-- forked from trunk for context.
local function branch_revset(sym)
	return ("(trunk()..%s) | ancestors(fork_point(trunk() | %s), 10)"):format(sym, sym)
end

local function bookmark_items(opts)
	if not opts.jj_root then return fail() end
	local bookmarks, err = jj.bookmarks(opts.jj_root)
	if not bookmarks then return fail(err) end

	local items, width = {}, 0
	for _, b in ipairs(bookmarks) do
		local label = b.remote and (b.name .. "@" .. b.remote) or b.name
		width = math.max(width, vim.fn.strdisplaywidth(label))
		items[#items + 1] = {
			text = label .. " " .. (b.description or ""),
			label = label,
			bookmark = b,
			root = opts.jj_root,
			revset = branch_revset(symbol(b)),
		}
	end
	for _, item in ipairs(items) do item.width = width end
	return items
end

local function format_bookmark(item)
	local b = item.bookmark
	local ret = { { pad(item.label, item.width), b.remote and "JumanjiDim" or "JumanjiBookmark" }, { " " } }
	if b.conflict then ret[#ret + 1] = { "(conflict) ", "JumanjiConflict" } end
	if b.change_id then
		ret[#ret + 1] = { b.change_id, "JumanjiChangeId" }
		ret[#ret + 1] = { " " }
	end
	ret[#ret + 1] = { b.description ~= "" and b.description or "(no description set)", b.description == "" and "JumanjiDim" or nil }
	return ret
end

local function log_items(opts)
	if not opts.jj_root then return fail() end
	local rows, err = jj.log(opts.jj_root, opts.revset)
	if not rows then return fail(err) end

	local items = {}
	for _, row in ipairs(rows) do
		local c = row.commit
		if c then
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
	local cmd = { "jj", "log", "--color=always", "--no-pager", "--ignore-working-copy", "-r", ctx.item.revset }
	return Snacks.picker.preview.cmd(cmd, ctx, { cwd = ctx.item.root })
end

M.sources = {
	--- Bookmarks, local and remote. Confirm opens the log of the branch.
	jj_bookmarks = {
		title = "jj bookmarks",
		config = with_root,
		finder = bookmark_items,
		format = format_bookmark,
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
