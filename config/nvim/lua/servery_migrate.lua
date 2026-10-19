local servery = require("servery")
local pi_label = require("servery.pi").label
local saved = require("servery.saved")

local M = {}

local RELOAD_TIMEOUT_MS = 20000
local RELOAD_POLL_MS = 1000

local RELOAD_CODE = [[
	local buf = ...
	vim.fn.chansend(vim.bo[buf].channel, "/reload\r")
]]

---Run Lua in the nvim of `sv`, over RPC unless that is this nvim.
---@param sv servery.SessionActive
---@param code string
---@param args any[]
local function exec(sv, code, args)
	if sv.server.socket == vim.v.servername then return vim.api.nvim_exec_lua(code, args) end

	local chan = vim.fn.sockconnect("pipe", sv.server.socket, { rpc = true })
	local ok, result = pcall(vim.rpcrequest, chan, "nvim_exec_lua", code, args)
	vim.fn.chanclose(chan)
	if not ok then error(result, 0) end
	return result
end

---@param sv servery.SessionActive
---@param pi servery.Pi
local function pi_key(sv, pi) return sv.server.socket .. "#" .. pi.buf end

---@param lines string[]
local function show(lines)
	vim.cmd("botright new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

---Ask for a save name until it is non-empty and unused. Returns nil to skip.
---@param sv servery.SessionActive
---@param taken table<string, true>
---@return string?
local function ask_name(sv, taken)
	local default = sv.server.name or vim.fs.basename(sv.server.original_cwd or sv.cwd)
	local problem

	while true do
		local prompt = ("Save name for %s%s: "):format(sv:display_name(), problem and (" (" .. problem .. ")") or "")
		local name = vim.trim(vim.fn.input(prompt, default))

		if name == "" then
			if vim.fn.confirm("The name can't be empty. Skip " .. sv:display_name() .. "?", "&Retry\n&Skip", 1) == 2 then
				return nil
			end
			problem = "empty"
		elseif taken[name] then
			default, problem = name, "already taken"
		else
			return name
		end
	end
end

function M.run()
	local sessions = servery.list_sessions("active")

	---@type { sv: servery.SessionActive, pi: servery.Pi, label: string }[]
	local reloaded = {}
	local not_converted = {} ---@type string[]

	for _, sv in ipairs(sessions) do
		for _, pi in ipairs(sv.server.pi) do
			if pi.status == "unknown" then
				local label = pi_label(pi, sv.cwd)
				local busy = pi.title and pi.title:find("^\xE2[\xA0-\xA3][\x80-\xBF]") ~= nil
				local choice = vim.fn.confirm(
					("Send /reload to pi in %s: %s?%s"):format(sv:display_name(), label, busy and " (BUSY: mid-turn)" or ""),
					"&Yes\n&No\n&Quit",
					busy and 2 or 1
				)

				if choice == 0 or choice == 3 then
					vim.notify("SvMigrate aborted, nothing saved", vim.log.levels.WARN)
					return
				elseif choice == 1 then
					local ok, err = pcall(exec, sv, RELOAD_CODE, { pi.buf })
					if ok then
						reloaded[#reloaded + 1] = { sv = sv, pi = pi, label = label }
					else
						not_converted[#not_converted + 1] = ("%s: %s (reload failed: %s)"):format(sv:display_name(), label, err)
					end
				else
					not_converted[#not_converted + 1] = ("%s: %s (declined)"):format(sv:display_name(), label)
				end
			end
		end
	end

	local pending = vim.list_slice(reloaded)
	vim.wait(RELOAD_TIMEOUT_MS, function()
		local status = {} ---@type table<string, string>
		for _, sv in ipairs(servery.list_sessions("active")) do
			for _, pi in ipairs(sv.server.pi) do
				status[pi_key(sv, pi)] = pi.status
			end
		end

		pending = vim.tbl_filter(function(r) return status[pi_key(r.sv, r.pi)] == "unknown" end, pending)
		return #pending == 0
	end, RELOAD_POLL_MS)

	for _, r in ipairs(pending) do
		not_converted[#not_converted + 1] = ("%s: %s (still unknown)"):format(r.sv:display_name(), r.label)
	end

	local taken = {} ---@type table<string, true>
	for _, s in ipairs(saved.list()) do
		taken[s.name] = true
	end

	local names = {} ---@type string[]
	local skipped = {} ---@type string[]

	for _, sv in ipairs(sessions) do
		local name = ask_name(sv, taken)
		if not name then
			skipped[#skipped + 1] = sv:display_name() .. " (no name)"
		else
			local socket = sv.server.socket ~= vim.v.servername and sv.server.socket or nil
			local ok, err = pcall(saved.save, { name = name, socket = socket })
			if ok and vim.iter(saved.list()):any(function(s) return s.name == name end) then
				taken[name] = true
				names[#names + 1] = name
			else
				skipped[#skipped + 1] = ("%s (save failed%s)"):format(sv:display_name(), ok and "" or ": " .. err)
			end
		end
	end

	local lines = { "SvMigrate", "" }
	local function section(title, entries)
		vim.list_extend(lines, { title .. ":" })
		vim.list_extend(lines, #entries > 0 and vim.tbl_map(function(e) return "  " .. e end, entries) or { "  none" })
		lines[#lines + 1] = ""
	end
	section("Saved", names)
	section("Pi not converted", not_converted)
	section("Skipped sessions", skipped)
	show(lines)
end

return M
