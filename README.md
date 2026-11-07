# test.nvim

[![CI](https://github.com/jrop/test.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/jrop/test.nvim/actions/workflows/ci.yml)

Shared test helpers for Neovim plugin specs. The library has three surfaces: a
child-Neovim RPC harness (`test.nvim`), deep equality with a line diff
(`test.assert`), and a temporary-window fixture (`test.with_buf`).

## Explanation

An example of the problem this library solves is a plugin that reacts to typing:
its behavior depends on autocmds, a real event loop, and the rendered screen, and
the host process running busted has none of those. The library therefore starts a
second Neovim as a child process and drives it over RPC, so the plugin under test
runs in an editor that behaves as it does interactively.

That split creates one constraint that the rest of the design follows from. The
host and the child are separate Lua states, so a function passed across the
boundary is serialized with `string.dump`, which keeps the code but drops every
upvalue; i.e., the child cannot see variables the spec closed over. State that
must survive between calls therefore lives in child globals, and data a function
needs arrives as an argument.

A second consequence is that the RPC round trip is the child's event-loop flush
point. When the host sends a request, the child handles it, runs its event loop,
and answers on the way back; effects caused by an input or command — the mode
change from `:startinsert`, a `TextChanged` autocmd, a `vim.schedule` callback —
become visible inside a later request, not in the one that caused them.

Read the first constraint as "no upvalues", and the second as "read state in a
later round trip", and the API's shape follows: `run` for single requests,
`drain` for scheduled work, and `wait_until` for a condition that becomes true
after some unspecified number of round trips.

The library keeps only helpers that a spec for an unrelated plugin could call
unchanged. A helper whose parameters name one plugin's data — a rendered
element, a tag, an event record — belongs in that plugin's own `_test`
directory, built from `run`, `drain`, and `wait_until`.

## Tutorial

Write a spec for a plugin that opens an input prompt and echoes what you type.
You will build it up one piece at a time, checking that each piece is visible
from the host before adding the next.

**1. Add the library to the runtimepath.** Vendor `lua/test/` into your
repository, or add it with your plugin manager. Your spec then requires it like
any other module.

**2. Start a child and stop it.** Every spec pair creates a fresh child, so one
spec's state cannot leak into the next:

```lua
local Nvim = require 'test.nvim'

describe('prompt', function()
  local nv --- @type test.Nvim

  before_each(function() nv = Nvim.start { columns = 80, rows = 12 } end)

  after_each(function() nv:stop() end)
end)
```

**3. Prove the child is alive.** `run` executes a function in the child and
returns its result:

```lua
it('answers from the child', function()
  assert.are.same({ 80, 12 }, nv:run(function() return { vim.o.columns, vim.o.lines } end))
end)
```

Run just this spec with `busted spec/prompt_spec.lua` and confirm it passes
before moving on; a child that never starts fails here, with `child nvim never
became ready`, rather than deep inside a later assertion.

**4. Type into the child.** `input` translates key notation and sends the keys
the way a terminal would:

```lua
local function lines()
  return nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end)
end

it('types text', function()
  nv:input 'ihello<Esc>'
  assert.are.same({ 'hello' }, lines())
end)
```

The read happens in a second `run`, because the keys typed in the first call are
only guaranteed to have taken effect by the time the next request arrives.

**5. Let the plugin settle.** A plugin that debounces work schedules it for a
later tick. `drain` waits for that scheduled work to finish:

```lua
it('renders after the debounce', function()
  nv:input 'ihello<Esc>'
  nv:drain(200)
  assert.are.same({ 'hello!' }, lines())
end)
```

`drain` waits on a sentinel queued after the pending work, so it returns as soon
as the queue empties; the number is only an upper bound.

**6. Assert on what the user sees.** `screen` returns the rendered grid, and
`assert_screenshot` compares it line for line, printing a diff on mismatch:

```lua
it('shows the prompt', function()
  local screen = nv:screen()
  assert.are.same(12, #screen.lines)
  assert.are.same(80, #screen.lines[1])
  nv:assert_screenshot({ 'expected first line', 'expected second line' })
end)
```

`screen.lines` holds one string per row, the status and command lines included,
so a full-screenshot assertion passes every row of the grid.

**7. Stop the child when the spec ends.** The `after_each` hook from step 2
already does this. Stopping matters even when a spec fails, because a child left
running keeps its event loop alive and can make a later spec's failures
confusing.

At this point you have a spec that starts an editor, types into it, waits for it
to settle, and checks both its state and its appearance. The
[how-to guides](#how-to-guides) cover the cases this walkthrough did not: async
plugins, conditions that do not settle on a fixed schedule, and failed
comparisons.

## How-to guides

### Wait for a condition that has no fixed deadline

`drain` covers work a plugin queues with `vim.schedule`, but a plugin's own
readiness condition (a loading spinner that stops, a count of unprocessed edits
that reaches zero) belongs to the plugin. `wait_until` polls a child-side
predicate until it returns true and gives up after a timeout, returning `false`:

```lua
local finished = nv:wait_until(function()
  local g = _G.my_plugin
  return g ~= nil and (g.pending or 0) == 0
end, 2000)
assert.is_true(finished, 'the plugin never finished processing the edit')
```

Each attempt is its own RPC round trip, because the round trip — not a wait
inside the child — is what lets the child dispatch pending events, so a
predicate that reads a child global sees the value change between attempts. Keep
the timeout well above the plugin's own settle time: when `wait_until` returns
`false`, the spec has already spent that whole timeout, so assert on the result
to turn the timeout into a labelled failure.

### Run something that takes longer than one round trip

An async plugin starts work and returns; the host continues. `run_async` passes
the child function a `done` callback and invokes `on_done` in the host with the
value passed to `done`:

```lua
local rendered
nv:run_async(function(done)
  vim.defer_fn(function() done 'ready' end, 50)
end, function(result) rendered = result end)
assert.is_true(vim.wait(1000, function() return rendered ~= nil end))
assert.are.same('ready', rendered)
```

The host must keep pumping its own loop while it waits, so pair the callback with
`vim.wait`; the callback cannot run while busted is blocked inside an assertion.

### Read several pieces of child state at once

Every `run` is one round trip, so collect what you need inside a single closure
rather than issuing one call per value:

```lua
local state = nv:run(function()
  return {
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), '\n'),
    events = _G.my_plugin_events or {},
    mode = vim.fn.mode(),
  }
end)
```

### Test the production timing path

The child starts with `NVIM_TEST=true`, a convention plugin suites use to
disable debounce and timers. A spec that tests the timing itself must unset it in
the child before the code under test runs:

```lua
nv:run(function() vim.env.NVIM_TEST = nil end)
```

### Compare two values with a readable failure

When `vim.deep_equal` is not enough on its own, use `deep_equal`, which raises an
error whose message contains a unified diff of the pretty-printed values:

```lua
local Assert = require 'test.assert'

Assert.deep_equal(got, want, 'after the second keystroke')
```

A failing call reads `deep_equal failed: after the second keystroke`, followed by
lines marked `-` for the got value and `+` for the wanted one.

### Work in a temporary window

`with_buf` opens a scratch window, loads your lines into it, runs your function,
and deletes the window even if the function raises. It is host-side, for specs
that exercise plugin code directly instead of through a child:

```lua
local Test = require 'test'

Test.with_buf({ 'alpha', 'beta' }, function()
  assert.are.same('alpha', vim.api.nvim_get_current_line())
end)
```

`swapfile` is disabled for that buffer only, so the editor's global setting is
unchanged afterward.

## Reference

### Requirements

- Neovim 0.12 or newer, for `vim.wait`, `screenstring`, and `vim.uv`.
- LuaJIT, as embedded in Neovim.

### `test.nvim`

| Call | Returns | Notes |
| --- | --- | --- |
| `Nvim.start(opts)` | `test.Nvim` | Spawns `nvim --headless --embed -n -u NORC` with `NVIM_TEST=true` and waits up to one second for readiness. |
| `nv:stop()` | — | Stops the child. Safe to call more than once. |
| `nv:request(method, ...)` | `any` | Synchronous RPC; blocks the host until the child answers. |
| `nv:notify(method, ...)` | — | Asynchronous RPC; returns immediately. |
| `nv:run(f, ...)` | `any` | Runs `f(...)` in the child and returns its result. `f` is `string.dump`'d, so it has no upvalues. |
| `nv:run_async(f, on_done)` | — | Runs `f(done)` in the child; `done(results)` calls `on_done(results)` in the host. Raises when `on_done` is not a function. |
| `nv:input(keys)` | `integer` | Translates key notation with `nvim_replace_termcodes` and sends it through `nvim_input`. |
| `nv:screen()` | `test.Screen` | Forces a redraw, then reads the grid cell by cell with `screenstring`. |
| `nv:assert_screenshot(expected, msg?)` | — | Compares `nv:screen().lines` with `expected`; raises on mismatch with a line diff. `msg` defaults to `screenshot mismatch` and becomes the error's first line. |
| `nv:drain(ms?)` | — | Waits until work already queued with `vim.schedule` has run. `ms` bounds the wait (default 1000). |
| `nv:wait_until(pred, timeout_ms?)` | `boolean` | Polls `pred()` in the child, one round trip per attempt, until it returns true or `timeout_ms` (default 2000) elapses. |

`Nvim.start` options:

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `columns` | `integer?` | child default | Sets `columns` in the child before startup. |
| `rows` | `integer?` | child default | Sets `lines` in the child before startup. |
| `rtp` | `string?` | `vim.fn.getcwd()` | Appended to the child's runtimepath, so the plugin under test is found when the child starts in the plugin's directory. |

`test.Screen`:

| Field | Type | Notes |
| --- | --- | --- |
| `lines` | `string[]` | One composited string per screen row, including the status and command lines. |
| `rows` | `integer` | Grid height, from `vim.o.lines`. |
| `columns` | `integer` | Grid width, from `vim.o.columns`. |

### `test.assert`

| Call | Returns | Notes |
| --- | --- | --- |
| `Assert.diff(got, want)` | `string` | Unified diff of two line lists, headed by `--- got` and `+++ want`. Unchanged lines are prefixed with two spaces, deletions with `- `, insertions with `+ `. A replacement appears as `-` then `+`. |
| `Assert.deep_equal(got, want, msg?)` | — | Returns when `vim.deep_equal` holds; otherwise raises an error whose message is the optional `msg` and a diff of the `vim.inspect`ed values. |

### `test`

| Call | Returns | Notes |
| --- | --- | --- |
| `Test.with_buf(lines?, f)` | — | Opens a scratch window with `lines`, runs `f`, and deletes the window even on error. `swapfile` is disabled for that buffer only. |
| `Test.Nvim` | `test.Nvim` | The same table as `require 'test.nvim'`. |
| `Test.assert` | `test.assert` | The same table as `require 'test.assert'`. |
