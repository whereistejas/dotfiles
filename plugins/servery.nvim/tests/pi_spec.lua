local h = require("helpers")
local pi = require("servery.pi")
local servery = require("servery")

h.test("pi label drops the spinner, the π prefix and a trailing dir", function()
	h.eq("fix tests", pi.label({ title = "⠋ π - fix tests - repo" }, "/x/repo"))
	h.eq("fix tests", pi.label({ title = "π — fix tests" }))
end)

h.test("pi label falls back to the session name, then the file, then 'pi'", function()
	h.eq("named", pi.label({ title = "π", name = "named" }))
	h.eq("2026-01-01_abc", pi.label({ file = "/s/2026-01-01_abc.jsonl" }))
	h.eq("pi", pi.label({}))
end)

h.test("a session lists its pi terminals", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[
		vim.cmd("terminal")
		vim.b.pi_session = { status = "idle", file = "/s/one.jsonl", name = "one" }
		vim.b.pi_branch = "main"
	]])

	local session = servery.list_sessions("active")[1]

	h.eq(1, #session.server.pi)
	local p = session.server.pi[1]
	h.eq({ "idle", "/s/one.jsonl", "one", "main" }, { p.status, p.file, p.name, p.branch })
end)

local pis_of = function(socket)
	return vim.iter(servery.list_sessions("active")):find(function(s) return s.server.socket == socket end).server.pi
end

h.test("a terminal running pi without the extension is listed with unknown status", function()
	local other = h.spawn(h.dir("other"))
	h.open_pi(other, {})

	local pis = pis_of(other)

	h.eq(1, #pis)
	h.eq("unknown", pis[1].status)
	h.eq(nil, pis[1].file)
end)

h.test("a pi's session file is read from its buffer name", function()
	local other = h.spawn(h.dir("other"))
	h.open_pi(other, { file = "/s/two.jsonl" })
	h.eq("/s/two.jsonl", pis_of(other)[1].file)
end)

h.test("a pi terminal whose job ended is listed as exited", function()
	local other = h.spawn(h.dir("other"))
	h.open_pi(other, { cmd = "true", session = { status = "idle" } })
	vim.wait(500)

	h.eq("exited", pis_of(other)[1].status)
end)

h.test("terminals that are not pi are not listed", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.fn.jobstart("sleep 100", { term = true })]])
	h.eq({}, pis_of(other))
end)

h.test("pi terminals report the tab and window showing them, or none when hidden", function()
	local other = h.spawn(h.dir("other"))
	local shown = h.open_pi(other, { tab = true, session = { status = "idle" } })
	local hidden = h.open_pi(other, { tab = true, session = { status = "idle" } })
	h.remote(other, "vim.cmd.enew()")

	local by_buf = {}
	for _, p in ipairs(pis_of(other)) do
		by_buf[p.buf] = p
	end

	h.eq(2, by_buf[shown].tab)
	h.truthy(by_buf[shown].win, "shown pi has no window")
	h.eq(nil, by_buf[hidden].win)
	h.eq(nil, by_buf[hidden].tab)
end)

h.test("jumping to a shown pi goes to its tab and window", function()
	local other = h.spawn(h.dir("other"))
	local buf = h.open_pi(other, { tab = true, session = { status = "idle" } })
	h.remote(other, "vim.cmd.tabfirst()")

	local session = servery.list_sessions("active")[1]
	pi.jump(session, session.server.pi[1])

	h.eq({ 2, buf }, h.remote(other, "return { vim.fn.tabpagenr(), vim.api.nvim_get_current_buf() }"))
	h.eq(2, h.remote(other, "return vim.fn.tabpagenr('$')"), "opened a new tab")
end)

h.test("jumping to a pi in another session switches there and keeps the current session running", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[
		vim.cmd("terminal")
		vim.b.pi_session = { status = "idle" }
		vim.cmd("enew")
	]])

	local session = servery.list_sessions("active")[1]
	pi.jump(session, session.server.pi[1])

	h.eq({ { server = other, bang = false } }, h.connects())
	h.eq("terminal", h.remote(other, "return vim.bo.buftype"))
end)
