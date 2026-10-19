local h = require("helpers")
local utils = require("servery.utils")
local servery = require("servery")

local find_session = function(socket)
	return vim.iter(servery.list_sessions("active")):find(function(s) return s.server.socket == socket end)
end

h.test("switch_to keeps the current session running when detach is nil", function()
	local other = h.spawn(h.dir("other"))
	utils.switch_to(other)
	h.eq({ { server = other, bang = false } }, h.connects())
end)

h.test("switch_to keeps the current session running when detach is false", function()
	local other = h.spawn(h.dir("other"))
	utils.switch_to(other, false)
	h.eq({ { server = other, bang = false } }, h.connects())
end)

h.test("switch_to stops the current session only when detach is true", function()
	local other = h.spawn(h.dir("other"))
	utils.switch_to(other, true)
	h.eq({ { server = other, bang = true } }, h.connects())
end)

h.test("switch_to does nothing when given the current session", function()
	utils.switch_to(vim.v.servername)
	utils.switch_to(vim.v.servername, true)
	h.eq({}, h.connects())
end)

h.test("switching to a running session keeps the current one running", function()
	local other = h.spawn(h.dir("other"))
	find_session(other):switch()
	h.eq({ { server = other, bang = false } }, h.connects())
end)

h.test("switch and detach to a running session stops the current one", function()
	local other = h.spawn(h.dir("other"))
	find_session(other):switch(true)
	h.eq({ { server = other, bang = true } }, h.connects())
end)

h.test("switching to an inactive dir starts nvim there and keeps the current one running", function()
	local dir = h.dir("fresh")
	h.setup({ dirs = { dir } })

	local session = servery.list_sessions("inactive")[1]
	h.eq(dir, session.cwd)
	session:switch()

	local connects = h.connects()
	h.eq(1, #connects)
	h.eq(false, connects[1].bang)
	h.truthy(h.wait_running(connects[1].server), "new session is not running")
	h.eq(dir, h.remote(connects[1].server, "return vim.fn.getcwd()"))
end)

h.test(":Sv <dir> for a dir with no session starts one and keeps the current one running", function()
	local dir = h.dir("fresh")
	vim.cmd.Sv(vim.fn.fnameescape(dir))

	local connects = h.connects()
	h.eq(1, #connects)
	h.eq(false, connects[1].bang)
	h.truthy(h.wait_running(connects[1].server), "new session is not running")
	h.eq(dir, h.remote(connects[1].server, "return vim.fn.getcwd()"))
end)

h.test(":Sv! <dir> starts a session there and stops the current one", function()
	local dir = h.dir("fresh")
	vim.cmd({ cmd = "Sv", args = { dir }, bang = true })

	local connects = h.connects()
	h.eq(1, #connects)
	h.eq(true, connects[1].bang)
end)

h.test(":Sv <name> switches to the running session with that name", function()
	local other = h.spawn(h.dir("other"))
	vim.cmd.Sv("other")
	h.eq({ { server = other, bang = false } }, h.connects())
end)

h.test(":Sv <missing dir> errors and does not switch", function()
	vim.cmd.Sv("/no/such/dir")
	h.eq({}, h.connects())
	h.eq({ "No such directory found '/no/such/dir'" }, h.notes(vim.log.levels.ERROR))
end)

h.test(":[N]Sv switches to the Nth other session and keeps the current one running", function()
	local other = h.spawn(h.dir("other"))
	vim.cmd({ cmd = "Sv", count = 1 })
	h.eq({ { server = other, bang = false } }, h.connects())
end)
