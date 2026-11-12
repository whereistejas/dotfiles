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

h.test("a branch on a remote shares its local bookmark's entry, starred when out of sync", function()
	local dir = stacks()
	local remote = vim.fs.joinpath(vim.fs.dirname(dir), "remote.git")
	vim.system({ "git", "init", "--bare", "-q", remote }):wait()
	h.jj(dir, { "git", "remote", "add", "origin", remote })
	for _, name in ipairs({ "b", "old" }) do
		if name == "old" then h.jj(dir, { "bookmark", "create", "old", "-r", "a" }) end
		h.jj(dir, { "bookmark", "track", name, "--remote=origin" })
		h.jj(dir, { "git", "push", "-b", name })
	end
	h.jj(dir, { "bookmark", "forget", "old" })
	h.jj(dir, { "new", "b", "-m", "b2" })
	h.jj(dir, { "bookmark", "set", "b", "-r", "@" })
	local nvim = h.nvim(dir)

	local items = h.lua(nvim, tree, { dir })

	h.eq({
		{ "main", "" },
		{ "a old@origin", "main" },
		{ "a-top", "a old@origin" },
		{ "b*", "main" },
	}, vim.tbl_map(function(i) return { i.label, i.parent } end, items))
	h.eq({ "b1", "b2" }, descriptions(dir, by_label(items)["b*"].preview))
end)

-- A glab on PATH that records its arguments and lists one open MR, for a.
local function fake_glab(nvim, dir)
	local bin = vim.fs.joinpath(vim.fs.dirname(dir), "fake-bin")
	vim.fn.mkdir(bin, "p")
	local script = vim.fs.joinpath(bin, "glab")
	vim.fn.writefile({
		"#!/bin/sh",
		'echo "$@" > ' .. vim.fn.shellescape(vim.fs.joinpath(bin, "args")),
		[[echo '[{"iid": 12, "source_branch": "a"}, {"iid": 13, "source_branch": "gone"}]']],
	}, script)
	vim.uv.fs_chmod(script, 493)
	h.lua(nvim, "vim.env.PATH = ... .. ':' .. vim.env.PATH", { bin })
	return vim.fs.joinpath(bin, "args")
end

local fetch_mrs = [[
	local done = false
	require("jumanji.mr").fetch(..., function() done = true end)
	vim.wait(5000, function() return done end, 20)
	return { done = done, mrs = require("jumanji.mr").get(...) }
]]

h.test("open GitLab MRs are fetched by source branch from origin", function()
	local dir = stacks()
	h.jj(dir, { "git", "remote", "add", "origin", "https://gitlab.com/g/p.git" })
	local nvim = h.nvim(dir)
	local args = fake_glab(nvim, dir)

	local out = h.lua(nvim, fetch_mrs, { dir })

	h.truthy(out.done, "the fetch never finished")
	h.eq({ a = 12, gone = 13 }, out.mrs)
	h.truthy(vim.fn.readfile(args)[1]:find("-R https://gitlab.com/g/p.git", 1, true), "glab wasn't pointed at origin")
end)

h.test("a repo without origin has no MRs and doesn't run glab", function()
	local dir = stacks()
	local nvim = h.nvim(dir)
	local args = fake_glab(nvim, dir)

	local out = h.lua(nvim, [[
		require("jumanji.mr").fetch(..., function() error("called back") end)
		vim.wait(300)
		return require("jumanji.mr").get(...)
	]], { dir })

	h.eq({}, out)
	h.eq(nil, vim.uv.fs_stat(args))
	h.not_blocked(nvim)
end)
