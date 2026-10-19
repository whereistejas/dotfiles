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
