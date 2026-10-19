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
