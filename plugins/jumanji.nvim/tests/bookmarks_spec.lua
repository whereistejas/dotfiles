local h = require("helpers")

-- main, with two stacks on it: a (a1) then a-top (a2, a3), and b (b1).
local function stacks()
	local dir = h.repo().main
	h.jj(dir, { "config", "set", "--repo", 'revset-aliases."trunk()"', "main" })
	h.jj(dir, { "bookmark", "create", "main", "-r", "@-" })
	for _, c in ipairs({ { "main", "a1", "a" }, { "@", "a2" }, { "@", "a3", "a-top" } }) do
		h.jj(dir, { "new", c[1], "-m", c[2] })
		if c[3] then h.jj(dir, { "bookmark", "create", c[3], "-r", "@" }) end
	end
	h.jj(dir, { "new", "main", "-m", "b1" })
	h.jj(dir, { "bookmark", "create", "b", "-r", "@" })
	return dir
end

local tree = [[
	local items = require("jumanji.picker").sources.jj_bookmarks.finder({ jj_root = ... })
	return vim.tbl_map(function(item)
		return {
			label = item.label,
			parent = item.parent and item.parent.label or "",
			last = item.last or false,
			preview = item.preview,
			revset = item.revset,
		}
	end, items)
]]

local function descriptions(dir, revset)
	local out = h.jj(dir, { "log", "--no-graph", "-r", revset, "-T", 'description.first_line() ++ "\n"' })
	local list = vim.split(out, "\n", { trimempty = true })
	table.sort(list)
	return list
end

local function by_label(items)
	local map = {}
	for _, item in ipairs(items) do map[item.label] = item end
	return map
end

h.test("the bookmark picker shows each stack as a branch of trunk's tree", function()
	local dir = stacks()
	local nvim = h.nvim(dir)

	local items = h.lua(nvim, tree, { dir })

	h.eq({
		{ "main", "", true },
		{ "a", "main", false },
		{ "a-top", "a", true },
		{ "b", "main", true },
	}, vim.tbl_map(function(i) return { i.label, i.parent, i.last } end, items))
end)

h.test("a bookmark's preview shows only its own commits, not the stack below it", function()
	local dir = stacks()
	local nvim = h.nvim(dir)

	local items = by_label(h.lua(nvim, tree, { dir }))

	h.eq({ "a2", "a3" }, descriptions(dir, items["a-top"].preview))
	h.eq({ "a1" }, descriptions(dir, items["a"].preview))
	h.eq({ "b1" }, descriptions(dir, items["b"].preview))
end)

h.test("confirming a bookmark opens its whole stack", function()
	local dir = stacks()
	local nvim = h.nvim(dir)

	local items = by_label(h.lua(nvim, tree, { dir }))

	local stack = descriptions(dir, items["a"].revset)
	for _, d in ipairs({ "a1", "a2", "a3", "first" }) do
		h.truthy(vim.tbl_contains(stack, d), d .. " missing from " .. vim.inspect(stack))
	end
	h.truthy(not vim.tbl_contains(stack, "b1"), "the other stack leaked in: " .. vim.inspect(stack))
end)
