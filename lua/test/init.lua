--- The library's one public surface. A bundle built with `nvim-bundle build
--- test` returns this table, so every helper a spec may call is exported here;
--- the other files under `lua/test/` are its implementation.
--- @class test
return {
  Nvim = require 'test.nvim',
  assert = require 'test.assert',
}
