# Tutorial: your first spec

In this tutorial, you will write a tiny plugin and a spec that drives it in a
real Neovim. By the end, the spec will start an editor, type into it, wait for
the plugin to react, and check what the screen shows.

You need Neovim 0.12 or newer and `git`. Nothing else: test.nvim runs the specs
itself, under `nvim -l`.

## 1. Create the project

Make a directory for the plugin, and clone test.nvim into it:

```sh
mkdir -p greet.nvim/lua/greet greet.nvim/spec
cd greet.nvim
git clone https://github.com/jrop/test.nvim deps/test.nvim
```

Every command from here on runs inside `greet.nvim`.

## 2. Write the plugin

Create `lua/greet/init.lua`:

```lua
local M = {}

function M.setup()
  vim.api.nvim_create_user_command('Greet', function(opts)
    -- Render on the next tick, the way many plugins defer their UI updates.
    vim.schedule(function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'Hello, ' .. opts.args .. '!' })
    end)
  end, { nargs = 1 })
end

return M
```

After `setup()`, the command `:Greet Ada` replaces the buffer with
`Hello, Ada!`, one tick later.

## 3. Write a first case

Create `spec/greet_spec.lua`:

```lua
local Test = require 'test'
local describe, it, before_each, after_each = Test.describe, Test.it, Test.before_each, Test.after_each
local Nvim, assert = Test.Nvim, Test.assert

describe('greet', function()
  local nv --- @type test.Nvim

  before_each(function() nv = Nvim.start { columns = 40, rows = 6 } end)
  after_each(function() nv:stop() end)

  it('answers from the child', function()
    assert.equal(nv:run(function() return 40 + 2 end), 42)
  end)
end)
```

Run it:

```sh
nvim --clean -l deps/test.nvim/lua/test/init.lua
```

You should see:

```text
spec/greet_spec.lua
  ✓ greet answers from the child

1 passed, 0 failed, 0 pending in 0.02s
```

Before the case ran, `before_each` started a child editor. The function you
passed to `run` executed inside that child, and its result came back to your
spec. Afterwards, `after_each` stopped the child.

## 4. Type into the child

Add this case below the first one, inside the `describe`:

```lua
  it('types into the buffer', function()
    nv:input 'iHi<Esc>'
    assert.deep_equal(nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end), { 'Hi' })
  end)
```

Run the specs again, and you should see two `✓` lines. `input` typed
`iHi<Esc>` into the child the way a terminal would, and a second `run` read the
buffer back.

## 5. Watch a case fail

Change `{ 'Hi' }` to `{ 'Hello' }`, and run the specs. The case fails, and the
report ends like this:

```text
✗ greet types into the buffer
spec/greet_spec.lua:17: deep_equal failed
expected equal contents
--- got
+++ want
- "Hi"
+ "Hello"
	spec/greet_spec.lua:17: in function <spec/greet_spec.lua:15>

1 passed, 1 failed, 0 pending in 0.04s
```

The `-` line is what the buffer holds, and the `+` line is what you asked for.
Change `{ 'Hello' }` back to `{ 'Hi' }`, and run the specs once more to see
them pass.

## 6. Use the plugin

Add a third case:

```lua
  it('greets by name', function()
    nv:run(function() require('greet').setup() end)
    nv:input ':Greet Ada<CR>'
    nv:wait_until(function()
      return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'Hello, Ada!'
    end, 1000, 'the greeting never appeared')
  end)
```

Run the specs, and you should see three `✓` lines. The child found your plugin
because `Nvim.start` adds the current directory to its runtimepath.
`wait_until` checked the buffer again and again until the greeting, which the
plugin renders a tick later, appeared.

## 7. Check the screen

Add these lines at the end of the `greets by name` case:

```lua
    local screen = nv:screen()
    assert.equal(#screen, 6)
    assert.matches(screen[1], '^Hello, Ada!%s*$')
```

Run the specs a final time, and you should see all three cases pass. `screen`
returned the child's six rows as strings, and the first row shows the greeting
exactly as a user would see it.

## What you built

Your spec now starts a fresh editor for each case, types into it, loads your
plugin, waits for the plugin to react, and checks both the buffer and the
screen. From here:

- [Vendor the library](how-to.md#vendor-the-library) instead of cloning it.
- [Run part of the suite](how-to.md#run-part-of-the-suite) while you work.
- Read [why the library works this way](explanation.md), including why the
  function passed to `run` cannot see your spec's local variables.
