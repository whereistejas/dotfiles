local h = require("helpers")

local complete = function(cmd) return vim.fn.getcompletion(cmd .. " ", "cmdline") end

h.test(":SvStop <name> stops the session with that :SvName", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.g.servery_name = "work"]])

	vim.cmd.SvStop("work")

	h.truthy(h.wait_stopped(other), "named session is still running")
	h.eq({}, h.notes(vim.log.levels.WARN))
end)

h.test(":Sv <name> switches to the session with that :SvName", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.g.servery_name = "work"]])

	vim.cmd.Sv("work")

	h.eq({ { server = other, bang = false } }, h.connects())
end)

h.test("a :SvName wins over another session's folder name", function()
	local named = h.spawn(h.dir("named"))
	h.remote(named, [[vim.g.servery_name = "other"]])
	local folder = h.spawn(h.dir("other"))

	vim.cmd.SvStop("other")

	h.truthy(h.wait_stopped(named), "the session named 'other' is still running")
	h.truthy(h.is_running(folder), "the session in folder 'other' was stopped")
end)

h.test("a session with a :SvName can still be found by its folder name", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.g.servery_name = "work"]])

	vim.cmd.Sv("other")

	h.eq({ { server = other, bang = false } }, h.connects())
end)

h.test("a name shared by several sessions is an error and nothing is stopped or switched", function()
	local a = h.spawn(h.dir("a/git"))
	-- Sockets are named after the folder and the second they start in
	vim.wait(1100)
	local b = h.spawn(h.dir("b/git"))

	vim.cmd.SvStop("git")
	vim.cmd.Sv("git")

	vim.wait(300)
	h.truthy(h.is_running(a) and h.is_running(b), "a session was stopped")
	h.eq({}, h.connects())
	h.eq(2, #h.notes(vim.log.levels.ERROR))
	h.truthy(h.notes(vim.log.levels.ERROR)[1]:find("ambiguous", 1, true))
end)

h.test(":SvStop <name> errors when only an inactive dir has that name", function()
	local dir = h.dir("idle")
	h.setup({ dirs = { dir } })

	vim.cmd.SvStop(vim.fn.fnamemodify(dir, ":~"))

	h.eq(1, #h.notes(vim.log.levels.ERROR))
end)

h.test(":SvStop <name> returns once the session has stopped", function()
	local other = h.spawn(h.dir("other"))
	vim.cmd.SvStop("other")
	h.eq(false, h.is_running(other))
end)

h.test(":Sv and :SvStop complete :SvName for named sessions and folders for the rest", function()
	local named = h.spawn(h.dir("named"))
	h.remote(named, [[vim.g.servery_name = "work"]])
	h.spawn(h.dir("other"))

	local stop = complete("SvStop")
	table.sort(stop)
	h.eq({ "other", "work" }, stop)
	h.truthy(vim.tbl_contains(complete("Sv"), "work"), ":Sv does not complete :SvName")
end)
