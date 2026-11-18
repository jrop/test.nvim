--- The library's one public surface, and its command line. A bundle built with
--- `nvim-bundle build test` returns this table, so every helper a spec may call
--- is exported here; the other files under `lua/test/` are its implementation.
--- Executed as `nvim -l <this file>`, it runs spec files instead.

--- Whether this file is the script `nvim -l` is executing, rather than a
--- module being required. It reads the plain `arg`, not `_G.arg`: when a spec
--- requires a bundle that is already running, nvim-bundle runs this file again
--- with that `arg` empty, so the check says "module" by itself.
--- @return boolean
local function is_script()
  local info = debug.getinfo(1, 'S')
  local script = arg and arg[0]
  if not info or not script or info.source:sub(1, 1) ~= '@' then return false end
  local this = vim.fs.normalize(vim.fn.fnamemodify(info.source:sub(2), ':p'))
  return this == vim.fs.normalize(vim.fn.fnamemodify(script, ':p'))
end

if is_script() then
  -- A checkout has no `lua/` directory on `package.path`; this file is
  -- `<lua>/test/init.lua`, so `:h:h` is that directory. A bundle inlines its
  -- requires, so the extra path is harmless there.
  -- is_script() returned true, so arg[0] holds this file's path.
  local lua_dir = vim.fn.fnamemodify(arg[0] --[[@as string]], ':p:h:h')
  package.path = ('%s/?.lua;%s/?/init.lua;%s'):format(lua_dir, lua_dir, package.path)

  -- The script hands off to the command line before loading anything else, so
  -- a coverage run starts recording before the library's other modules load.
  -- In a checkout, a spec's `require 'test'` runs this file again and still
  -- sees the script's `arg`; the run already in progress tells it apart.
  local cli = require 'test.cli'
  if not cli.running() then os.exit(cli.main(arg)) end
end

local suite = require 'test.suite'

--- @class test
return {
  Nvim = require 'test.nvim',
  assert = require 'test.assert',
  describe = suite.describe,
  it = suite.it,
  pending = suite.pending,
  before_all = suite.before_all,
  after_all = suite.after_all,
  before_each = suite.before_each,
  after_each = suite.after_each,
}
