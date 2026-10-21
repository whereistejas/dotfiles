local M = {}

local function job_pid(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "terminal" then
    return nil
  end
  local ok, pid = pcall(vim.fn.jobpid, vim.bo[buf].channel)
  return ok and pid or nil
end

-- The terminal buffer running pi: its job pid is one of pi's ancestors.
local function find(a)
  local wanted = {}
  for _, pid in ipairs(a.pids) do
    wanted[pid] = true
  end

  if a.buf and wanted[job_pid(a.buf)] then
    return a.buf
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if wanted[job_pid(buf)] then
      return buf
    end
  end
end

-- Shell-quotes `s` without backslashes, which :mksession turns into slashes.
-- Returns nil when that isn't possible.
local function quote(s)
  if s:match("^[%w%%%+,./:=@_-]+$") then
    return s
  elseif not s:find("[\\']") then
    return "'" .. s .. "'"
  elseif not s:find('[\\"$`!]') then
    return '"' .. s .. '"'
  end
end

-- Neovim names a terminal term://<cwd>//<pid>:<command> and :mksession restores
-- it by running <command> again, so naming the command `pi --session <file>`
-- makes a restored terminal resume this session.
local function rename(buf, cwd, file)
  local quoted = quote(file)
  if not quoted then
    return
  end

  local old = vim.api.nvim_buf_get_name(buf)
  local old_cwd, old_pid = old:match("^term://(.-)//(%d+):")
  local name = string.format(
    "term://%s//%s:pi --session %s",
    old_cwd or cwd,
    old_pid or job_pid(buf),
    quoted
  )
  if old == name then
    return
  end

  -- Renaming leaves an unlisted buffer with the old name behind, which
  -- :mksession could restore as a terminal running the old command.
  local before = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    before[b] = true
  end
  if pcall(vim.api.nvim_buf_set_name, buf, name) then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not before[b] and vim.api.nvim_buf_get_name(b) == old then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
  end
end

function M.register(a)
  local buf = find(a)
  if not buf then
    return {}
  end

  if a.file then
    rename(buf, a.session.cwd, a.file)
  end
  vim.b[buf].pi_session = a.session
  return { buf = buf }
end

function M.update(a)
  local buf = find(a)
  if not buf then
    return {}
  end

  local session = vim.b[buf].pi_session
  if type(session) == "table" then
    session.status = a.status
    session.name = a.name
    vim.b[buf].pi_session = session
  end
  return { buf = buf }
end

function M.clear(a)
  local buf = find(a)
  if buf then
    vim.b[buf].pi_session = nil
  end
  return { buf = buf }
end

return M
