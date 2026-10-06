local M = {}

-- The window showing the terminal that runs pi: its job pid is one of pi's ancestors.
local function pi_window(pids)
  local wanted = {}
  for _, pid in ipairs(pids) do
    wanted[pid] = true
  end
  local wins = vim.list_extend(vim.api.nvim_tabpage_list_wins(0), vim.api.nvim_list_wins())
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      local ok, pid = pcall(vim.fn.jobpid, vim.bo[buf].channel)
      if ok and wanted[pid] then
        return win, buf
      end
    end
  end
end

local function show(buf, pids)
  local win, own = pi_window(pids)
  if own then
    vim.bo[own].bufhidden = "hide"
  end
  vim.api.nvim_win_set_buf(win or 0, buf)
  return own
end

function M.open(a)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_buf_call(buf, function()
    vim.fn.jobstart(a.cmd, {
      term = true,
      cwd = a.cwd,
      on_exit = a.exit_file and function(_, code)
        local tail = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, -60, -1, false) or {}
        vim.fn.writefile({ vim.json.encode({ code = code, tail = tail }) }, a.exit_file)
      end,
    })
  end)
  vim.b[buf].pi_branch = a.name
  local own = a.show and show(buf, a.pids) or select(2, pi_window(a.pids))
  return { buf = buf, own = own }
end

function M.show(a)
  if not vim.api.nvim_buf_is_valid(a.buf) then
    return { error = "its terminal buffer is gone" }
  end
  show(a.buf, a.pids)
  return {}
end

return M
