local h = require("helpers")

local modify_file = function()
	local file = vim.fs.joinpath(h.dir("edits"), "file.txt")
	vim.cmd.edit(vim.fn.fnameescape(file))
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
	return file
end

h.test(":SvStop with unsaved changes refuses to close the current session", function()
	h.spawn(h.dir("other"))
	modify_file()

	vim.cmd.SvStop()

	h.eq({}, h.connects())
	h.eq({}, h.state().quits)
	h.eq(1, #h.notes(vim.log.levels.ERROR))
	h.truthy(h.notes(vim.log.levels.ERROR)[1]:find("unsaved changes", 1, true))
end)

h.test(":SvStop ignores modified non-file buffers", function()
	local other = h.spawn(h.dir("other"))
	vim.cmd("enew")
	vim.bo.buftype = "nofile"
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })

	vim.cmd.SvStop()

	h.eq({ { server = other, bang = true } }, h.connects())
end)

h.test(":SvStop! closes the current session despite unsaved changes", function()
	local other = h.spawn(h.dir("other"))
	modify_file()

	vim.cmd({ cmd = "SvStop", bang = true })

	h.eq({ { server = other, bang = true } }, h.connects())
end)

h.test(":SvStop moves the UI to another running session and stops the current one", function()
	local other = h.spawn(h.dir("other"))

	vim.cmd.SvStop()

	h.eq({ { server = other, bang = true } }, h.connects())
	h.eq({}, h.state().quits)
	h.truthy(h.is_running(other), "the session moved to was stopped")
end)

h.test(":SvStop quits when no other session is running", function()
	vim.cmd.SvStop()

	h.eq({}, h.connects())
	h.eq({ "qall!" }, h.state().quits)
end)

h.test(":SvStop <name> stops that session and leaves the current one alone", function()
	local other = h.spawn(h.dir("other"))
	local keep = h.spawn(h.dir("keep"))

	vim.cmd.SvStop("other")

	h.truthy(h.wait_stopped(other), "named session is still running")
	h.truthy(h.is_running(keep), "unrelated session was stopped")
	h.eq({}, h.connects())
	h.eq({}, h.state().quits)
end)

h.test(":SvStop <name> refuses to stop a session with unsaved changes", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[
		vim.cmd.edit(vim.fn.fnameescape(vim.fn.getcwd() .. "/file.txt"))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
	]])

	vim.cmd.SvStop("other")

	vim.wait(300)
	h.truthy(h.is_running(other), "session with unsaved changes was stopped")
	h.eq(1, #h.notes(vim.log.levels.WARN))
	h.truthy(h.notes(vim.log.levels.WARN)[1]:find("unsaved changes", 1, true))
end)

h.test(":[N]SvStop stops the Nth other session", function()
	local other = h.spawn(h.dir("other"))

	vim.cmd({ cmd = "SvStop", count = 1 })

	h.truthy(h.wait_stopped(other), "session is still running")
	h.eq({}, h.connects())
	h.eq({}, h.state().quits)
end)

local find_session = function(socket)
	return vim.iter(require("servery").list_sessions("active")):find(function(s) return s.server.socket == socket end)
end

h.test("stopping another session stops it and leaves the UI where it is", function()
	local other = h.spawn(h.dir("other"))

	find_session(other):stop()

	h.eq(false, h.is_running(other))
	h.eq({}, h.connects())
	h.eq({}, h.state().quits)
end)

h.test("stopping the current session moves the UI to another running session", function()
	local other = h.spawn(h.dir("other"))
	h.setup({ servers = function() return { vim.v.servername } end })

	find_session(vim.v.servername):stop()

	h.eq({ { server = other, bang = true } }, h.connects())
end)

h.test("stopping the current session refuses unsaved changes unless forced", function()
	local other = h.spawn(h.dir("other"))
	h.setup({ servers = function() return { vim.v.servername } end })
	modify_file()
	local current = find_session(vim.v.servername)

	current:stop()
	h.eq({}, h.connects())

	current:stop(true)
	h.eq({ { server = other, bang = true } }, h.connects())
end)
