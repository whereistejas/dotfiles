local d = vim.diagnostic.get(0)
local out = {}
for _, e in ipairs(d) do
  local sev = ({ "ERROR", "WARN", "INFO", "HINT" })[e.severity] or "?"
  table.insert(out, (e.lnum + 1) .. ":" .. (e.col + 1) .. " " .. sev .. " " .. e.message)
end
if #out == 0 then
  print("No diagnostics")
else
  print(table.concat(out, "\n"))
end
