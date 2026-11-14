# Tutorial: your first spec

In this tutorial, you will write a tiny plugin and a spec that drives it in a
real Neovim. By the end, the spec will start an editor, type into it, wait for
the plugin to react, and check what the screen shows.

You need Neovim 0.12 or newer and `git`. You do not need a test runner: the
spec is a plain Lua script that `nvim -l` runs, and it stops at the first
failed check.

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

## 3. Start a child editor

Create `spec/greet_spec.lua`:

```lua
package.path = 'deps/test.nvim/lua/?.lua;deps/test.nvim/lua/?/init.lua;' .. package.path

local Test = require 'test'
local Nvim, assert = Test.Nvim, Test.assert

local nv = Nvim.start { columns = 40, rows = 6 }

assert.equal(nv:run(function() return 40 + 2 end), 42)

nv:stop()
print 'all checks passed'
```

Run it:

```sh
nvim --clean -l spec/greet_spec.lua
```

You should see `all checks passed`. The function you passed to `run` executed
inside the child editor, and its result came back to your script.

## 4. Type into the child

Add these lines before `nv:stop()`:

```lua
nv:input 'iHi<Esc>'
assert.deep_equal(nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end), { 'Hi' })
```

Run the spec again, and you should see `all checks passed`. `input` typed
`iHi<Esc>` into the child the way a terminal would, and a second `run` read the
buffer back.

## 5. Watch a check fail

Change `{ 'Hi' }` to `{ 'Hello' }`, and run the spec. It stops with an error
like this one:

```text
spec/greet_spec.lua:11: deep_equal failed
expected equal contents
--- got
+++ want
- "Hi"
+ "Hello"
```

The `-` line is what the buffer holds, and the `+` line is what you asked for.
Change `{ 'Hello' }` back to `{ 'Hi' }`, and run the spec once more to see it
pass.

## 6. Use the plugin

Add these lines before `nv:stop()`:

```lua
nv:run(function() require('greet').setup() end)
nv:input ':Greet Ada<CR>'
nv:wait_until(function()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'Hello, Ada!'
end, 1000, 'the greeting never appeared')
```

Run the spec, and you should see `all checks passed`. The child found your
plugin because `Nvim.start` adds the current directory to its runtimepath.
`wait_until` checked the buffer again and again until the greeting, which the
plugin renders a tick later, appeared.

## 7. Check the screen

Add these lines before `nv:stop()`:

```lua
local screen = nv:screen()
assert.equal(#screen, 6)
assert.matches(screen[1], '^Hello, Ada!%s*$')
```

Run the spec a final time, and you should see `all checks passed`. `screen`
returned the child's six rows as strings, and the first row shows the greeting
exactly as a user would see it.

## What you built

Your spec now starts an editor, types into it, loads your plugin, waits for the
plugin to react, and checks both the buffer and the screen. From here:

- [Run your specs under busted](how-to.md#run-specs-under-busted), so that
  each check is its own test.
- [Vendor the library](how-to.md#vendor-the-library) instead of cloning it.
- Read [why the library works this way](explanation.md), including why the
  function passed to `run` cannot see your script's local variables.
