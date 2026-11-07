--- Host-side buffer fixture for specs that need a temporary window.
--- @class test
local M = {}

--- Run `f` inside a temporary scratch window, cleaned up afterward (bdelete
--- fires the teardown autocmds). Sets `swapfile` buffer-locally so the editor's
--- global default survives the helper.
--- @param lines string[]?  initial lines (nil leaves the buffer empty)
--- @param f fun()
function M.with_buf(lines, f)
  vim.cmd.new()
  vim.opt_local.swapfile = false
  if lines then vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
  local ok, result = pcall(f)
  vim.cmd.bdelete { bang = true }
  if not ok then error(result) end
end

M.Nvim = require 'test.nvim'
M.assert = require 'test.assert'

return M
