local M = {}

local REQUEST_TTL_MS = 10000

-- This file is dofile'd on every call, so requests in flight live in a global.
_G.pi_mention_symbols = _G.pi_mention_symbols or {}

local function related(dir, cwd)
  return vim.fs.relpath(dir, cwd) ~= nil or vim.fs.relpath(cwd, dir) ~= nil
end

-- Clients whose workspace contains the cwd or lies inside it.
local function clients(cwd)
  return vim.tbl_filter(function(client)
    if not client:supports_method("workspace/symbol") then
      return false
    end
    local dirs = vim.tbl_map(function(folder)
      return vim.uri_to_fname(folder.uri)
    end, client.workspace_folders or {})
    dirs[#dirs + 1] = client.root_dir
    return vim.iter(dirs):any(function(dir)
      return related(dir, cwd)
    end)
  end, vim.lsp.get_clients())
end

local function symbol(item)
  local range = item.location.range
  return {
    name = item.name,
    kind = vim.lsp.protocol.SymbolKind[item.kind] or "Unknown",
    container = item.containerName ~= "" and item.containerName or nil,
    file = vim.uri_to_fname(item.location.uri),
    line = range and range.start.line + 1,
    col = range and range.start.character + 1,
  }
end

local function start(cwd, query)
  local request = { started = vim.uv.now(), pending = 0, symbols = {} }
  for _, client in ipairs(clients(cwd)) do
    request.pending = request.pending + 1
    local sent = client:request("workspace/symbol", { query = query }, function(err, result)
      request.pending = request.pending - 1
      for _, item in ipairs(not err and result or {}) do
        request.symbols[#request.symbols + 1] = symbol(item)
      end
    end)
    if not sent then
      request.pending = request.pending - 1
    end
  end
  return request
end

-- Starts `workspace/symbol` on the first call for `a.id` and reports `done` with the
-- symbols once every client has answered, so pi polls without blocking the editor.
function M.symbols(a)
  local requests = _G.pi_mention_symbols
  local now = vim.uv.now()
  for id, request in pairs(requests) do
    if now - request.started > REQUEST_TTL_MS then
      requests[id] = nil
    end
  end

  requests[a.id] = requests[a.id] or start(a.cwd, a.query)
  local request = requests[a.id]
  if request.pending > 0 then
    return { done = false }
  end
  requests[a.id] = nil
  return { done = true, symbols = request.symbols }
end

return M
