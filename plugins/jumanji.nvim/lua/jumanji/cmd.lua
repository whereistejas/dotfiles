local jj = require("jumanji.jj")

local M = {}

local SCRIPT = vim.fs.joinpath(
	vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))),
	"scripts", "editor.lua"
)

-- Subcommands whose output jj would page: shown in a split instead.
local PAGED = {
	diff = true, show = true, log = true, evolog = true, interdiff = true,
	op = true, operation = true, file = true, help = true,
}

-- Subcommands that run jj's diff editor, a full-screen terminal UI.
local INTERACTIVE = { split = true, diffedit = true, resolve = true }

local SUBCOMMANDS = {
	"abandon", "absorb", "bisect", "bookmark", "commit", "config", "describe", "diff",
	"diffedit", "duplicate", "edit", "evolog", "file", "fix", "git", "help", "interdiff",
	"log", "metaedit", "new", "next", "operation", "parallelize", "prev", "rebase",
	"redo", "resolve", "restore", "revert", "root", "show", "sign", "simplify-parents",
	"sparse", "split", "squash", "status", "tag", "undo", "unsign", "util", "version",
	"workspace",
}

--- Open a file jj wants edited, for scripts/editor.lua. jj resumes once the
--- buffer is wiped, i.e. when its window is closed.
---@param file string
function M.edit(file)
	vim.cmd("split " .. vim.fn.fnameescape(file))
	vim.bo.bufhidden = "wipe"
end

-- Paged output keeps its colours (jj's, or an external diff formatter's):
-- a terminal buffer renders the ANSI codes.
local function show_paged(lines)
	if lines[#lines] == "" then table.remove(lines) end
	vim.cmd.new()
	vim.bo.bufhidden = "wipe"
	local chan = vim.api.nvim_open_term(0, {})
	vim.api.nvim_chan_send(chan, table.concat(lines, "\r\n"))
	vim.schedule(function() vim.cmd("normal! gg") end)
end

-- `log`, optionally with only a revset: jumanji's own log view. Returns
-- whether it matched, and the revset.
local function log_view_revset(args)
	if args == "log" then return true, nil end
	local revset = args:match("^log%s+%-r%s*(.+)$") or args:match("^log%s+%-%-revisions[=%s]%s*(.+)$")
	if not revset then return false end
	return true, vim.trim(revset):gsub([[^(['"])(.*)%1$]], "%2")
end

local function run_job(args, paged)
	local stdout, stderr
	vim.fn.jobstart(("jj --color=%s "):format(paged and "always" or "never") .. args, {
		env = {
			JJ_EDITOR = table.concat({
				vim.fn.shellescape(vim.v.progpath), "--clean", "-l", vim.fn.shellescape(SCRIPT),
			}, " "),
		},
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data) stdout = data end,
		on_stderr = function(_, data) stderr = data end,
		on_exit = function(_, code)
			local out = vim.trim(table.concat(stdout or {}, "\n"))
			local err = vim.trim(table.concat(stderr or {}, "\n"))
			if code == 0 and paged and out ~= "" then
				show_paged(stdout)
				out = ""
			end
			local msg = vim.trim(out .. "\n" .. err)
			if msg ~= "" then
				vim.api.nvim_echo({ { msg, code ~= 0 and "ErrorMsg" or nil } }, true, {})
			end
		end,
	})
end

--- Handler for :J {args}.
---@param args string
function M.run(args)
	args = vim.trim(vim.fn.expandcmd(args))
	local is_log, revset = log_view_revset(args)
	if args == "" or is_log then
		require("jumanji").open(revset)
		return
	end

	local words = vim.split(args, "%s+")
	local sub = words[1]
	local interactive = INTERACTIVE[sub]
	for _, w in ipairs(words) do
		if w == "-i" or w == "--interactive" or w == "--tool" or w:match("^%-%-tool=") then interactive = true end
	end

	if interactive then
		vim.cmd.new()
		vim.fn.jobstart("jj " .. args, { term = true })
		vim.cmd.startinsert()
		return
	end

	run_job(args, PAGED[sub] or vim.tbl_contains(words, "--help") or vim.tbl_contains(words, "-h"))
end

--- Completion for :J: subcommands for the first word, then change ids and
--- bookmarks, fuzzy-matched against what's typed.
function M.complete(arglead, cmdline, cursorpos)
	local before = cmdline:sub(1, cursorpos)
	local first_word = not before:match("^%s*%S+%s+%S+%s")
	local candidates = first_word and SUBCOMMANDS or jj.refs(vim.fs.root(0, ".jj") or vim.fn.getcwd())
	if arglead == "" then return candidates end
	return vim.fn.matchfuzzy(candidates, arglead)
end

return M
