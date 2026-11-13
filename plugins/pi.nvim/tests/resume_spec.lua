local h = require("helpers")

-- Saves a session from an nvim with a hidden pi terminal and a hidden other
-- terminal, restores it in a new 120x40 nvim, and returns that nvim.
local function restore_hidden_terminals()
	h.fake_pi()
	local session = vim.fs.joinpath(h.dir(), "Session.vim")

	local old = h.spawn()
	h.remote(old, [[
		local file, session = ...
		for _, cmd in ipairs({ "pi --session " .. file, "sleep 100" }) do
			local buf = vim.api.nvim_create_buf(true, false)
			vim.bo[buf].bufhidden = "hide"
			vim.api.nvim_buf_call(buf, function() vim.fn.jobstart(cmd, { term = true, width = 80, height = 24 }) end)
		end
		vim.cmd.mksession(vim.fn.fnameescape(session))
	]], { vim.fs.joinpath(h.dir(), "s.jsonl"), session })

	local new = h.spawn()
	h.remote(new, "vim.o.columns, vim.o.lines = 120, 40; vim.cmd.source(vim.fn.fnameescape(...))", { session })
	return new
end

local function terminals(socket)
	return h.remote(socket, [[
		local out = {}
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			local cmd = vim.api.nvim_buf_get_name(buf):match("^term://.-//%d+:(.*)$")
			if cmd then
				local lines = vim.tbl_filter(function(l) return l ~= "" end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
				out[cmd] = { loaded = vim.api.nvim_buf_is_loaded(buf), shown = #vim.fn.win_findbuf(buf) > 0, last = lines[#lines] }
			end
		end
		return out
	]])
end

h.test("a restored session starts its hidden pi terminals, still hidden", function()
	local nvim = restore_hidden_terminals()
	local cmd = "pi --session " .. vim.fs.joinpath(h.dir(), "s.jsonl")

	local pi
	h.truthy(vim.wait(3000, function()
		pi = terminals(nvim)[cmd]
		return pi and pi.last ~= nil
	end, 50), "the hidden pi terminal never ran: " .. vim.inspect(terminals(nvim)))

	h.eq({ loaded = true, shown = false }, { loaded = pi.loaded, shown = pi.shown })
	local args = vim.fn.readfile(vim.fs.joinpath(h.dir(), "pi-args"))
	h.eq({ "--session " .. vim.fs.joinpath(h.dir(), "s.jsonl") }, { args[#args] })
end)

h.test("a resumed hidden pi terminal is the size of the current window", function()
	local nvim = restore_hidden_terminals()
	local cmd = "pi --session " .. vim.fs.joinpath(h.dir(), "s.jsonl")
	local size = h.remote(nvim, [[
		local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
		return info.height .. " " .. (info.width - info.textoff)
	]])

	h.truthy(vim.wait(3000, function()
		local pi = terminals(nvim)[cmd]
		return pi and pi.last == size
	end, 50), ("expected size %s, got %s"):format(size, vim.inspect(terminals(nvim)[cmd])))
end)

h.test("a restored session starts a shown pi terminal only once", function()
	h.fake_pi()
	local session = vim.fs.joinpath(h.dir(), "Session.vim")
	local cmd = "pi --session " .. vim.fs.joinpath(h.dir(), "shown.jsonl")
	local starts = function()
		local args = vim.fn.readfile(vim.fs.joinpath(h.dir(), "pi-args"))
		return #vim.tbl_filter(function(a) return "pi " .. a == cmd end, args)
	end

	local old = h.spawn()
	h.remote(old, "vim.fn.jobstart(..., { term = true })", { cmd })
	h.truthy(vim.wait(3000, function() return vim.uv.fs_stat(vim.fs.joinpath(h.dir(), "pi-args")) ~= nil end, 20))
	h.remote(old, "vim.cmd.mksession(vim.fn.fnameescape(...))", { session })

	local new = h.spawn()
	h.remote(new, "vim.cmd.source(vim.fn.fnameescape(...))", { session })

	h.truthy(vim.wait(3000, function() return starts() >= 2 end, 20), "the shown pi terminal never restarted")
	vim.wait(300)
	h.eq(2, starts())
end)

h.test("a restored session skips hidden pi terminals whose directory is gone", function()
	h.fake_pi()
	local session = vim.fs.joinpath(h.dir(), "Session.vim")
	local gone = vim.fs.joinpath(h.dir(), "gone")
	vim.fn.mkdir(gone, "p")
	local kept = "pi --session " .. vim.fs.joinpath(h.dir(), "kept.jsonl")

	local old = h.spawn()
	h.remote(old, [[
		local gone, kept, session = ...
		for _, job in ipairs({ { "pi --session gone.jsonl", gone }, { kept, vim.fn.getcwd() } }) do
			local buf = vim.api.nvim_create_buf(true, false)
			vim.bo[buf].bufhidden = "hide"
			vim.api.nvim_buf_call(buf, function()
				vim.fn.jobstart(job[1], { term = true, cwd = job[2], width = 80, height = 24 })
			end)
		end
		vim.cmd.mksession(vim.fn.fnameescape(session))
	]], { gone, kept, session })
	vim.fn.delete(gone, "rf")

	local new = h.spawn()
	h.remote(new, "vim.cmd.source(vim.fn.fnameescape(...))", { session })

	h.truthy(vim.wait(3000, function()
		local pi = terminals(new)[kept]
		return pi and pi.last ~= nil
	end, 50), "the pi terminal after the missing one never ran: " .. vim.inspect(terminals(new)))
	h.eq(false, terminals(new)["pi --session gone.jsonl"].loaded)
	local messages = vim.split(h.remote(new, "return vim.api.nvim_exec2('messages', { output = true }).output"), "\n")
	h.eq({ "pi: not resuming 1 terminal whose directory is gone" }, messages)
end)

h.test("a restored session leaves other hidden terminals unstarted", function()
	local nvim = restore_hidden_terminals()

	vim.wait(300)
	h.eq(false, terminals(nvim)["sleep 100"].loaded)
end)
