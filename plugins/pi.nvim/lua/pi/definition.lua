local M = {}

---@class pi.Symbol
---@field symbol lsp.SymbolInformation|lsp.WorkspaceSymbol
---@field client vim.lsp.Client

--- The word under the cursor and the one qualifying it with `::` or `.`, as in
--- `Yield::of` or `scope.resolve`.
---@param line string
---@param col integer 0-based byte column
---@return string? name
---@return string? qualifier
local function word_at(line, col)
	for start, word, stop in line:gmatch("()([%w_]+)()") do
		if start <= col + 1 and col + 1 < stop then
			local before = line:sub(1, start - 1)
			return word, before:match("([%w_]+)::$") or before:match("([%w_]+)%.$")
		end
	end
end

-- The type a symbol is declared on, without generics: `Kind<'r>` is `Kind`.
local function container(symbol)
	return symbol.containerName and symbol.containerName:gsub("<.*", "")
end

-- The module a file is: its stem, or its directory for `mod.rs`.
local function module(file)
	local stem = vim.fn.fnamemodify(file, ":t:r")
	return stem == "mod" and vim.fs.basename(vim.fs.dirname(file)) or stem
end

local function file(symbol)
	return vim.uri_to_fname(symbol.location.uri)
end

--- Symbols named `name`. A qualifier keeps those on that type or in that module,
--- unless none are.
---@param symbols pi.Symbol[]
---@param name string
---@param qualifier string?
---@return pi.Symbol[]
local function pick(symbols, name, qualifier)
	local named = vim.tbl_filter(function(s) return s.symbol.name == name end, symbols)
	if not qualifier then return named end

	local qualified = vim.tbl_filter(function(s)
		return container(s.symbol) == qualifier or module(file(s.symbol)) == qualifier
	end, named)
	return #qualified > 0 and qualified or named
end

local function related(dir, cwd)
	return vim.fs.relpath(dir, cwd) ~= nil or vim.fs.relpath(cwd, dir) ~= nil
end

-- Clients whose workspace contains `cwd` or lies inside it.
local function clients(cwd)
	return vim.tbl_filter(function(client)
		local dirs = vim.tbl_map(function(folder) return vim.uri_to_fname(folder.uri) end, client.workspace_folders or {})
		table.insert(dirs, client.root_dir)
		return client:supports_method("workspace/symbol")
			and vim.iter(dirs):any(function(dir) return related(dir, cwd) end)
	end, vim.lsp.get_clients())
end

---@param cwd string
---@param query string
---@param done fun(symbols: pi.Symbol[])
local function search(cwd, query, done)
	local found, pending = {}, 0
	local function finish()
		pending = pending - 1
		if pending == 0 then done(found) end
	end

	local targets = clients(cwd)
	if #targets == 0 then return done(found) end
	pending = #targets
	for _, client in ipairs(targets) do
		local sent = client:request("workspace/symbol", { query = query }, function(err, result)
			for _, symbol in ipairs(not err and result or {}) do
				table.insert(found, { symbol = symbol, client = client })
			end
			finish()
		end)
		if not sent then finish() end
	end
end

local function is_code(win)
	return vim.api.nvim_win_get_config(win).relative == ""
		and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

-- The previous window if it shows code, else the first in the tab that does,
-- else a new split beside the terminal.
local function code_window()
	local previous = vim.fn.win_getid(vim.fn.winnr("#"))
	if previous ~= 0 and is_code(previous) then return previous end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_code(win) then return win end
	end
	vim.cmd("leftabove vsplit")
	return vim.api.nvim_get_current_win()
end

---@param target pi.Symbol
local function show(target)
	vim.api.nvim_set_current_win(code_window())
	vim.lsp.util.show_document(target.symbol.location, target.client.offset_encoding, { focus = true })
end

---@param target pi.Symbol
---@param cwd string
local function label(target, cwd)
	local symbol = target.symbol
	local name = symbol.containerName and container(symbol) .. "::" .. symbol.name or symbol.name
	local range = symbol.location.range
	local path = vim.fs.relpath(cwd, file(symbol)) or file(symbol)
	return ("%s  %s%s"):format(name, path, range and ":" .. (range.start.line + 1) or "")
end

--- Jump from a pi terminal to the definition of the symbol under the cursor,
--- found through `workspace/symbol` on the LSP clients for pi's directory. It
--- opens in a code window so the terminal stays in view.
function M.jump()
	local cwd = require("pi").cwd()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local name, qualifier = word_at(vim.api.nvim_get_current_line(), cursor[2])
	if not cwd or not name then return end

	local terminal = vim.api.nvim_get_current_win()
	search(cwd, name, function(symbols)
		vim.schedule(function()
			if vim.api.nvim_get_current_win() ~= terminal then return end

			local targets = pick(symbols, name, qualifier)
			if #targets == 0 then
				vim.notify("pi: no definition of " .. name, vim.log.levels.WARN)
			elseif #targets == 1 then
				show(targets[1])
			else
				vim.ui.select(targets, {
					prompt = "Definition of " .. name,
					format_item = function(target) return label(target, cwd) end,
				}, function(target)
					if target then show(target) end
				end)
			end
		end)
	end)
end

return M
