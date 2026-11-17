local h = require("helpers")
local servery = require("servery")

local title_of = function(socket)
	local session = vim.iter(servery.list_sessions("active")):find(function(s) return s.server.socket == socket end)
	return session:title()
end

h.test("a session's title is its :SvName name", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.g.servery_name = "my work"]])
	h.eq("my work", title_of(other))
end)

h.test("a session's title is the focused terminal's title, without a trailing dir", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[
		vim.cmd.edit(vim.fn.fnameescape(vim.fn.getcwd() .. "/file.txt"))
		vim.cmd("split | terminal")
		vim.b.term_title = "fixing bugs - other"
	]])
	h.eq("fixing bugs", title_of(other))
end)

h.test("a session's title is the focused file when there is no named terminal", function()
	local other = h.spawn(h.dir("other"))
	h.remote(other, [[vim.cmd.edit(vim.fn.fnameescape(vim.fn.getcwd() .. "/sub/file.txt"))]])
	h.eq("sub/file.txt", title_of(other))
end)

h.test("a session with nothing open has no title", function()
	local other = h.spawn(h.dir("other"))
	h.eq(nil, title_of(other))
end)
