local h = require("helpers")
local saved = require("servery.saved")

local names = function(list) return vim.tbl_map(function(s) return s.name end, list) end

h.test("saving a session writes it and names the running nvim", function()
	local dir = h.dir("other")
	local other = h.spawn(dir)

	saved.save({ name = "work", socket = other })

	h.truthy(vim.uv.fs_stat(vim.fs.joinpath(h.saved_dir(), "work.vim")), "no .vim file")
	h.truthy(vim.uv.fs_stat(vim.fs.joinpath(h.saved_dir(), "work.json")), "no .json file")
	h.eq("work", h.remote(other, "return vim.g.servery_name"))
	h.eq({ "work" }, names(saved.list()))
	h.eq(dir, saved.list()[1].cwd)
end)

h.test("closed saves exclude sessions that are still running", function()
	local other = h.spawn(h.dir("other"))
	saved.save({ name = "work", socket = other })

	h.eq({}, names(saved.list({ closed = true })))

	h.remote(other, "vim.defer_fn(function() vim.cmd('qall!') end, 10)")
	h.truthy(h.wait_stopped(other), "session did not stop")
	h.eq({ "work" }, names(saved.list({ closed = true })))
end)

h.test("restoring a save starts it in its dir and keeps the current session running", function()
	local dir = h.dir("other")
	local other = h.spawn(dir)
	saved.save({ name = "work", socket = other })
	h.remote(other, "vim.defer_fn(function() vim.cmd('qall!') end, 10)")
	h.truthy(h.wait_stopped(other), "session did not stop")

	saved.restore("work")

	local connects = h.connects()
	h.eq(1, #connects)
	h.eq(false, connects[1].bang)
	h.truthy(h.wait_running(connects[1].server), "restored session is not running")
	h.eq(dir, h.remote(connects[1].server, "return vim.fn.getcwd()"))
	h.eq("work", h.remote(connects[1].server, "return vim.g.servery_name"))
end)

h.test("restoring a save that is already running refuses", function()
	local other = h.spawn(h.dir("other"))
	saved.save({ name = "work", socket = other })

	saved.restore("work")

	h.eq({}, h.connects())
	h.eq({ "Session 'work' is already running" }, h.notes(vim.log.levels.ERROR))
end)

h.test("invalid save names are rejected", function()
	local other = h.spawn(h.dir("other"))
	for _, name in ipairs({ "a/b", ".hidden", "" }) do
		saved.save({ name = name, socket = other })
	end
	h.eq({}, saved.list())
	h.eq(3, #h.notes(vim.log.levels.ERROR))
end)

h.test("deleting a save removes it", function()
	local other = h.spawn(h.dir("other"))
	saved.save({ name = "work", socket = other })

	saved.delete("work")

	h.eq({}, saved.list())
end)

local read_json = function(name)
	return vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(h.saved_dir(), name .. ".json")), "\n"))
end

h.test("a save records the pi sessions it will resume, skipping exited and unresumable ones", function()
	local other = h.spawn(h.dir("other"))
	h.open_pi(other, { file = "/s/one.jsonl", session = { status = "idle", name = "one" }, branch = "main" })
	h.open_pi(other, { session = { status = "idle" } })
	h.open_pi(other, { cmd = "true", file = "/s/gone.jsonl", session = { status = "idle" } })
	vim.wait(500)

	saved.save({ name = "work", socket = other })

	h.eq({ { file = "/s/one.jsonl", name = "one", branch = "main" } }, read_json("work").pi)
end)

h.test("restoring a save brings back its tabs and resumes each pi with its session file", function()
	local log = h.fake_pi()
	local other = h.spawn(h.dir("other"))
	h.open_pi(other, { file = "/s/one.jsonl", session = { status = "idle" } })
	h.open_pi(other, { tab = true, file = "/s/two.jsonl", session = { status = "idle" } })
	saved.save({ name = "work", socket = other })
	h.remote(other, "vim.defer_fn(function() vim.cmd('qall!') end, 10)")
	h.truthy(h.wait_stopped(other), "session did not stop")

	saved.restore("work")
	local restored = h.connects()[1].server
	h.truthy(h.wait_running(restored), "restored session is not running")

	h.eq(2, h.remote(restored, "return vim.fn.tabpagenr('$')"))
	h.truthy(
		vim.wait(3000, function() return vim.fn.filereadable(log) == 1 and #vim.fn.readfile(log) == 2 end, 50),
		"pi was not started for each terminal"
	)
	local args = vim.fn.readfile(log)
	table.sort(args)
	h.eq({ "--session /s/one.jsonl", "--session /s/two.jsonl" }, args)
end)

h.test("saving with no name uses the session's :SvName", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.g.servery_name = "named"]])

	saved.save({ socket = other })

	h.eq({ "named" }, names(saved.list()))
end)

h.test("saving another session with no name and no :SvName errors", function()
	local other = h.spawn(h.dir("other"))

	saved.save({ socket = other })

	h.eq({}, saved.list())
	h.eq(1, #h.notes(vim.log.levels.ERROR))
end)

h.test(":SvSave <name> saves the current session", function()
	vim.cmd.SvSave("here")

	h.eq({ "here" }, names(saved.list()))
	h.eq(vim.fn.getcwd(), saved.list()[1].cwd)
	h.eq("here", vim.g.servery_name)
end)

h.test("saving again under the same name overwrites the save", function()
	local first, second = h.dir("first"), h.dir("second")
	saved.save({ name = "work", socket = h.spawn(first) })
	saved.save({ name = "work", socket = h.spawn(second) })

	h.eq({ "work" }, names(saved.list()))
	h.eq(second, saved.list()[1].cwd)
end)

h.test("sessions are only saved by hand, not when they stop", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.g.servery_name = "named"]])

	vim.cmd.SvStop("other")
	h.truthy(h.wait_stopped(other), "session did not stop")

	h.eq({}, saved.list())
end)
