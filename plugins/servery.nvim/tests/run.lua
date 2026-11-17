local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(root)
package.path = vim.fs.joinpath(root, "tests", "?.lua") .. ";" .. package.path

local h = require("helpers")

for name, kind in vim.fs.dir(vim.fs.joinpath(root, "tests")) do
	if kind == "file" and name:match("_spec%.lua$") then
		require(name:gsub("%.lua$", ""))
	end
end

os.exit(h.run(arg[1]) and 0 or 1)
