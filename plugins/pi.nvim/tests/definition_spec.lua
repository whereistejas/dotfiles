local h = require("helpers")

local SYMBOLS = {
	{ name = "of", kind = 12, containerName = "Yield<'_>", file = "src/check.rs", line = 4 },
	{ name = "of", kind = 12, containerName = "Kind<'r>", file = "src/resolve/mod.rs", line = 2 },
	{ name = "offset", kind = 12, file = "src/check.rs", line = 1 },
	{ name = "resolve", kind = 12, containerName = "Scope", file = "src/scope.rs", line = 3 },
	{ name = "resolve", kind = 12, file = "src/avro.rs", line = 5 },
	{ name = "walk", kind = 12, file = "src/resolve/mod.rs", line = 6 },
}

-- A fake `pi` that prints `text`, a project with the files SYMBOLS points into, and
-- an nvim with an in-process LSP server for that project answering workspace/symbol.
local function setup(text)
	local dir = h.dir()
	local bin = vim.fs.joinpath(dir, "bin")
	vim.fn.mkdir(bin, "p")
	vim.fn.writefile({ "#!/bin/sh", "printf '%s\\n' " .. vim.fn.shellescape(text), "sleep 100" }, vim.fs.joinpath(bin, "pi"))
	vim.fn.setfperm(vim.fs.joinpath(bin, "pi"), "rwxr-xr-x")

	vim.fn.mkdir(vim.fs.joinpath(dir, "src", "resolve"), "p")
	for _, file in ipairs({ "src/check.rs", "src/resolve/mod.rs", "src/scope.rs", "src/avro.rs" }) do
		vim.fn.writefile({ "1", "2", "3", "4", "    fn here() {}", "6", "7" }, vim.fs.joinpath(dir, file))
	end

	local nvim = h.spawn()
	h.remote(nvim, [[
		local dir, symbols = ...
		vim.lsp.start({
			name = "fake",
			root_dir = dir,
			cmd = function()
				local closing = false
				local id = 0
				return {
					request = function(method, params, callback)
						id = id + 1
						local result
						if method == "initialize" then
							result = { capabilities = { workspaceSymbolProvider = true } }
						elseif method == "workspace/symbol" then
							result = {}
							for _, s in ipairs(symbols) do
								if s.name:find(params.query, 1, true) then
									local pos = { line = s.line - 1, character = 4 }
									table.insert(result, {
										name = s.name, kind = s.kind, containerName = s.containerName,
										location = { uri = vim.uri_from_fname(dir .. "/" .. s.file), range = { start = pos, ["end"] = pos } },
									})
								end
							end
						end
						vim.schedule(function() callback(nil, result) end)
						return true, id
					end,
					notify = function() return true end,
					is_closing = function() return closing end,
					terminate = function() closing = true end,
				}
			end,
		}, { attach = false })
		vim.wait(1000, function() return #vim.lsp.get_clients({ name = "fake" }) > 0 end)
	]], { dir, SYMBOLS })
	return nvim
end

-- Opens a code window and a pi terminal beside it, unless `alone`, and puts the
-- cursor on `word` in the terminal.
local function open_pi(nvim, text, word, alone)
	h.remote(nvim, [[
		local dir, text, word, alone = ...
		if not alone then
			vim.cmd.edit(dir .. "/src/scope.rs")
			vim.cmd("rightbelow vsplit | enew")
		end
		vim.fn.jobstart("pi", { term = true })
		vim.wait(3000, function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == text end, 20)
		vim.cmd.stopinsert()
		local col = text:find(word, 1, true)
		vim.api.nvim_win_set_cursor(0, { 1, col - 1 })
	]], { h.dir(), text, word, alone or false })
end

local function gd(nvim)
	h.remote(nvim, "vim.cmd.normal('gd')")
end

-- File and line shown in each window of the tab, and the current window's index.
local function layout(nvim)
	return h.remote(nvim, [[
		local dir = ...
		local wins, current = {}, nil
		for i, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].buftype == "terminal" then
				wins[i] = "pi"
			else
				local name = vim.api.nvim_buf_get_name(buf):sub(#dir + 2)
				wins[i] = name .. ":" .. vim.api.nvim_win_get_cursor(win)[1]
			end
			if win == vim.api.nvim_get_current_win() then current = i end
		end
		return { wins = wins, current = current }
	]], { h.dir() })
end

local function wait_layout(nvim, expected)
	local got
	vim.wait(3000, function()
		got = layout(nvim)
		return vim.deep_equal(expected, got)
	end, 20)
	h.eq(expected, got)
end

h.test("gd on Type::method in a pi terminal opens the definition in the code window", function()
	local nvim = setup("see Yield::of here")
	open_pi(nvim, "see Yield::of here", "of")
	gd(nvim)
	wait_layout(nvim, { wins = { "src/check.rs:4", "pi" }, current = 1 })
end)

h.test("gd matches a free function by the module it is in, mod.rs by its directory", function()
	local nvim = setup("avro::resolve and resolve::walk")
	open_pi(nvim, "avro::resolve and resolve::walk", "resolve")
	gd(nvim)
	wait_layout(nvim, { wins = { "src/avro.rs:5", "pi" }, current = 1 })

	h.remote(nvim, "vim.cmd.wincmd('l'); vim.api.nvim_win_set_cursor(0, { 1, 27 })")
	gd(nvim)
	wait_layout(nvim, { wins = { "src/resolve/mod.rs:6", "pi" }, current = 1 })
end)

h.test("gd splits a code window off when the tab has none", function()
	local nvim = setup("see Yield::of here")
	open_pi(nvim, "see Yield::of here", "of", true)
	gd(nvim)
	wait_layout(nvim, { wins = { "src/check.rs:4", "pi" }, current = 1 })
end)

h.test("gd lets you pick when several symbols match", function()
	local nvim = setup("see of here")
	h.remote(nvim, [[
		vim.ui.select = function(items, opts, choose)
			_G.offered = vim.tbl_map(opts.format_item, items)
			choose(items[2])
		end
	]])
	open_pi(nvim, "see of here", "of")
	gd(nvim)
	wait_layout(nvim, { wins = { "src/resolve/mod.rs:2", "pi" }, current = 1 })
	h.eq({ "Yield::of  src/check.rs:4", "Kind::of  src/resolve/mod.rs:2" }, h.remote(nvim, "return _G.offered"))
end)

h.test("gd without a qualifier offers symbols with and without a container", function()
	local nvim = setup("see resolve here")
	h.remote(nvim, [[
		vim.ui.select = function(items, opts) _G.offered = vim.tbl_map(opts.format_item, items) end
	]])
	open_pi(nvim, "see resolve here", "resolve")
	gd(nvim)
	vim.wait(1000, function() return h.remote(nvim, "return _G.offered") ~= nil end, 20)
	h.eq({ "Scope::resolve  src/scope.rs:3", "resolve  src/avro.rs:5" }, h.remote(nvim, "return _G.offered"))
end)

h.test("gd says so when nothing matches", function()
	local nvim = setup("see nothing here")
	open_pi(nvim, "see nothing here", "nothing")
	h.remote(nvim, "_G.messages = {}; vim.notify = function(msg) table.insert(_G.messages, msg) end")
	gd(nvim)
	vim.wait(500, function() return #h.remote(nvim, "return _G.messages") > 0 end, 20)
	h.eq({ "pi: no definition of nothing" }, h.remote(nvim, "return _G.messages"))
	h.eq({ wins = { "src/scope.rs:1", "pi" }, current = 2 }, layout(nvim))
end)
