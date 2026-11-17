local h = require("helpers")

local open_log = [[
	require("jumanji").open(nil, ...)
	return vim.api.nvim_get_current_buf()
]]

local has_lines = [[
	local lines = vim.api.nvim_buf_get_lines(..., 0, -1, false)
	return #lines > 1 and lines
]]

local notice = [[
	local ns = vim.api.nvim_get_namespaces()["jumanji-stale"]
	local marks = ns and vim.api.nvim_buf_get_extmarks(..., ns, 0, -1, { details = true }) or {}
	return marks[1] and marks[1][4].virt_text[1][1]
]]

local no_notice = "return not (function(...) " .. notice .. " end)(...)"

local count_stale_messages = function(nvim)
	local n = 0
	for line in vim.gsplit(h.messages(nvim), "\n") do
		if line:find("stale", 1, true) then n = n + 1 end
	end
	return n
end

h.test("a log whose working copy goes stale keeps its lines and shows a notice", function()
	local repo = h.repo()
	local nvim = h.nvim(repo.main)
	local buf = h.lua(nvim, open_log, { repo.main })
	local before = h.wait_for(nvim, has_lines, { buf })

	h.make_stale(repo)

	h.truthy(h.wait_for(nvim, notice, { buf }), "no stale notice")
	h.truthy(h.lua(nvim, notice, { buf }):find("U", 1, true), "the notice doesn't mention U")
	h.eq(before, h.lua(nvim, has_lines, { buf }))
end)

h.test("a stale log warns once, in one line, however often it refreshes", function()
	local repo = h.repo()
	local nvim = h.nvim(repo.main)
	local buf = h.lua(nvim, open_log, { repo.main })
	h.wait_for(nvim, has_lines, { buf })

	h.make_stale(repo)
	h.wait_for(nvim, notice, { buf })
	h.jj(repo.other, { "describe", "-m", "another operation" })
	h.lua(nvim, [[require("jumanji").refresh_root(...)]], { repo.main })
	h.lua(nvim, [[require("jumanji").refresh_root(...)]], { repo.main })

	h.not_blocked(nvim)
	h.eq(1, count_stale_messages(nvim))
end)

h.test("a log opened on a stale working copy shows the notice", function()
	local repo = h.repo()
	h.make_stale(repo)
	local nvim = h.nvim(repo.main)

	local buf = h.lua(nvim, open_log, { repo.main })

	h.truthy(h.wait_for(nvim, notice, { buf }), "no stale notice")
end)

h.test("U in the log updates the stale working copy and clears the notice", function()
	local repo = h.repo()
	local nvim = h.nvim(repo.main)
	local buf = h.lua(nvim, open_log, { repo.main })
	h.wait_for(nvim, has_lines, { buf })
	h.make_stale(repo)
	h.wait_for(nvim, notice, { buf })

	vim.rpcrequest(nvim.chan, "nvim_input", "U")

	h.truthy(h.wait_for(nvim, no_notice, { buf }), "the notice stayed")
	h.jj(repo.main, { "log", "-r", "@" })
	h.eq(1, count_stale_messages(nvim))
end)
