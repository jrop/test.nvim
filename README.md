# test.nvim

[![CI](https://github.com/jrop/test.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/jrop/test.nvim/actions/workflows/ci.yml)

Test helpers for Neovim plugins. A spec starts a second Neovim as a child
process, drives it over RPC the way a user would, and checks the results with
assertions whose every failure prints a diff.

```lua
-- spec/typing_spec.lua
local Test = require 'test'
local describe, it = Test.describe, Test.it
local Nvim, assert = Test.Nvim, Test.assert

describe('typing', function()
  it('inserts text', function()
    local nv = Nvim.start { columns = 80, rows = 24 }
    nv:input 'ihello<Esc>'
    assert.deep_equal(nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end), { 'hello' })
    nv:stop()
  end)
end)
```

```sh
nvim --clean -l lua/test/init.lua   # or the vendored copy: lua/<plugin>/vendor/test.lua
```

The library is one file when vendored with
[nvim-bundle](https://github.com/jrop/nvim-bundle). Required, it returns the
child harness (`Nvim`), the assertions (`assert`), and the spec API
(`describe`, `it`, `pending`, `before_all`, `after_all`, `before_each`,
`after_each`). Run with `nvim -l`,
it finds and runs your specs, so a plugin's tests need nothing but Neovim.

## Documentation

The documentation follows [Diátaxis](https://diataxis.fr/), so each document
has one job:

| Document | Read it when you want to |
| --- | --- |
| [Tutorial](docs/tutorial.md) | learn the library by writing your first spec, step by step |
| [How-to guides](docs/how-to.md) | get a specific task done: vendor the library, run part of the suite, wait for a plugin, check an error |
| [Reference](docs/reference.md) | look up exactly what a function takes, returns, and raises |
| [Explanation](docs/explanation.md) | understand why the library is shaped the way it is |

## Requirements

- Neovim 0.12 or newer, which provides `vim.wait`, `screenstring`, and `vim.uv`.
- LuaJIT, as embedded in Neovim.

## Development

Tasks run through [mise](https://mise.jdx.dev/): `mise run ci` checks
formatting, type-checks with `emmylua_check`, and runs the specs. See
[AGENTS.md](AGENTS.md) for the full list.
