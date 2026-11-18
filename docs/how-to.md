# How-to guides

Each guide gets one task done. The guides assume that you have written a spec
before; the [tutorial](tutorial.md) covers that.

The examples use these names:

```lua
local Test = require 'test'
local describe, it, pending = Test.describe, Test.it, Test.pending
local before_all, after_all = Test.before_all, Test.after_all
local before_each, after_each = Test.before_each, Test.after_each
local Nvim, assert = Test.Nvim, Test.assert
```

## Vendor the library

Vendor test.nvim into your plugin as one file with
[nvim-bundle](https://github.com/jrop/nvim-bundle):

```sh
nvim-bundle install --dev jrop/test.nvim test
```

This writes `lua/<your-plugin>/vendor/test.lua` and records the dependency
under `dev_dependencies` in `nvim-bundle.json`, so a bundle built from your
plugin leaves the runner out. Require it by that path:

```lua
local Test = require '<your-plugin>.vendor.test'
```

Without a ref, `install` uses the newest release tag; append `@<tag>` to the
repository to pin one. Run `nvim-bundle install` with no arguments to rebuild
the vendored file from `nvim-bundle.json`.

Use nvim-bundle 0.4.1 or newer. Your specs require the same file that the
command line is running, and only 0.4.1 and newer bundles share their modules
between those two loads. A bundle built by an older version fails its first
spec file with `loop or previous error loading module`.

## Run your specs

Run the vendored file with `nvim -l` from your plugin's root:

```sh
nvim --clean -l lua/<your-plugin>/vendor/test.lua
```

With no arguments, it runs every `*_spec.lua` file under `spec/`. Your
plugin's `lua/` directory is on `package.path`, so specs can `require` its
modules. The command exits with status 1 when any case fails.

## Run part of the suite

Pass a directory, a file, or a glob, and narrow by case name with `--filter`:

```sh
nvim --clean -l lua/<your-plugin>/vendor/test.lua spec/ui
nvim --clean -l lua/<your-plugin>/vendor/test.lua spec/ui/render_spec.lua
nvim --clean -l lua/<your-plugin>/vendor/test.lua 'spec/**/*_spec.lua' --exclude 'spec/slow/**'
nvim --clean -l lua/<your-plugin>/vendor/test.lua --filter 'renders a tag'
```

`--filter` keeps the cases whose full name, i.e., the `describe` names and the
`it` name joined by spaces, contains the text. Quote globs, so the shell does
not expand them first.

## Run the suite in parallel

Add `--isolate file` to run each spec file in its own process, as many at once
as you have CPUs:

```sh
nvim --clean -l lua/<your-plugin>/vendor/test.lua --isolate file
```

When one file holds most of the suite's time, run each case in its own
process instead:

```sh
nvim --clean -l lua/<your-plugin>/vendor/test.lua --isolate case
```

Add `-j <n>` to cap the processes at `<n>`. The report prints in file order,
the same as a run in one process.

Two things must hold for a parallel run to pass where a serial one does:

1. A file must declare the same cases, in the same order, every time it loads,
   because each worker loads it again and runs its cases by position. Build
   case names from literals or from sorted lists, never from `pairs()`, the
   clock, or the file system.
2. Files that run at once must not share a fixed path, a port, or other state
   outside the process. Make each fixture with `vim.fn.tempname()`.

## Find the case that crashes the run

When the run dies with a signal, such as `killed by SIGSEGV`, and prints no
summary, rerun it isolated, with a timeout in case a case hangs:

```sh
nvim --clean -l lua/<your-plugin>/vendor/test.lua --isolate file --timeout 10000
```

The case whose worker crashed fails with `the worker was killed by signal
<n>`, and its output follows under `output:`. A case that calls `os.exit`
fails the same way, with `the worker exited with code <n>`. The cases after
it in the same file fail with `did not run`, because they shared the dead
worker; add `--isolate case` instead to give each case its own worker and its
own result.

Add `-j 1` to run one worker at a time, which keeps the crash from racing
other workers when it depends on the machine's load.

## Share setup between cases

Put the setup in `before_each` and the cleanup in `after_each`, inside the
`describe` whose cases need them:

```lua
describe('my plugin', function()
  local nv --- @type test.Nvim

  before_each(function() nv = Nvim.start { columns = 80, rows = 24 } end)
  after_each(function() nv:stop() end)

  it('starts empty', function()
    assert.deep_equal(nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end), { '' })
  end)
end)
```

`after_each` runs even when the case fails, so the child is always stopped.

## Share expensive setup across a scope

Use `before_all` and `after_all` for setup that every case in a scope can
share, such as a fixture directory:

```lua
describe('project files', function()
  local dir

  before_all(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/lua', 'p')
  end)
  after_all(function() vim.fn.delete(dir, 'rf') end)

  it('finds the lua directory', function() assert.equal(vim.fn.isdirectory(dir .. '/lua'), 1) end)
end)
```

Keep a child editor in `before_each`: a fresh child per case is what keeps one
case's editor state out of the next.

## Measure coverage

Add `--coverage`:

```sh
nvim --clean -l lua/<your-plugin>/vendor/test.lua --coverage
```

After the summary, the report lists each file under `lua/` with its covered
share of lines and the lines that never ran. Stop every child you start, with
`nv:stop()` in an `after_each`, because a child writes its lines as it exits,
and a child still running when the run ends contributes nothing.

`--coverage` combines with `--isolate`, which counts the lines each worker
runs. A worker that `--timeout` kills contributes nothing.

## Leave code out of coverage

Put the code between two marker lines, the ones luacov reads:

```lua
-- luacov: disable
local function only_on_windows()
  return vim.fn.has 'win32' == 1
end
-- luacov: enable
```

A `disable` with no `enable` after it leaves out the rest of the file. Give
the region a comment that says why it cannot run under the suite, so the
next reader can tell a deliberate gap from a forgotten test.

## Test a plugin's `nvim -l` script

Run it with `Nvim.script`, and check its output and exit status:

```lua
it('rejects a missing file', function()
  local proc = Nvim.script('lua/my_plugin/cli.lua', { 'missing.txt' })
  assert.equal(proc.code, 1)
  assert.contains(proc.stderr, 'missing.txt')
end)
```

A coverage run counts the script's lines too, including the lines it reaches
before an `os.exit`.

## Mark a case unfinished

Declare it with `pending`, which reports it without running anything:

```lua
pending('renders nested tags')
```

## Run the specs in CI

Install Neovim, check out your plugin, and run the same command:

```yaml
- uses: actions/checkout@v7
- uses: rhysd/action-setup-vim@v1
  with:
    neovim: true
    version: v0.12.5
- run: nvim --clean -l lua/<your-plugin>/vendor/test.lua
```

No Lua, luarocks, or test runner needs installing. CI logs are not a
terminal, so the output is plain; add `--color` if your CI renders ANSI
colors.

## Load the plugin under test

The child adds your plugin's directory to its runtimepath after it has started,
so `require` finds your modules, but your `plugin/` files have not run. Call
your setup function:

```lua
nv:run(function() require('my_plugin').setup() end)
```

If your plugin defines its commands in `plugin/` files, source them instead:

```lua
nv:run(function() vim.cmd 'runtime! plugin/**/*.lua' end)
```

If the child starts somewhere other than your plugin's directory, pass that
directory as `rtp`:

```lua
nv = Nvim.start { rtp = '/path/to/my_plugin' }
```

## Wait for scheduled work

Call `drain` after an action whose effects the plugin queues with
`vim.schedule`:

```lua
nv:input 'ihello<Esc>'
nv:drain()
```

`drain` returns once the work queued so far has run. It does not wait for
timers such as `vim.defer_fn`; use `wait_until` for those.

## Wait for a plugin's own condition

Poll a child-side predicate with `wait_until`, and say what should have
happened:

```lua
nv:wait_until(function()
  local g = _G.my_plugin
  return g ~= nil and (g.pending or 0) == 0
end, 2000, 'the plugin never finished processing the edit')
```

The predicate runs in the child, so it reads the child's state, and it cannot
use your spec's local variables. Choose a timeout well above the plugin's own
settle time, because a failing `wait_until` spends the whole timeout before it
raises.

## Run work that finishes later

Pass `run_async` a function that calls `done` with its result, and wait for the
result:

```lua
local value = nv:run_async(function(done)
  vim.defer_fn(function() done 'ready' end, 50)
end):wait()
assert.equal(value, 'ready')
```

To run several jobs at once, start them all before waiting on any:

```lua
local a = nv:run_async(job_a)
local b = nv:run_async(job_b)
assert.deep_equal({ a:wait(), b:wait() }, { 'A', 'B' })
```

## React to a result without blocking

Register a callback with `on_settled`, do other work, and wait for the callback
before you assert:

```lua
local seen
nv:run_async(job):on_settled(function(ok, value) seen = { ok, value } end)
nv:input 'ihello<Esc>'
vim.wait(1000, function() return seen ~= nil end)
assert.deep_equal(seen, { true, 'ready' })
```

Assert after the wait, not inside the callback: an error raised by the callback
does not fail the spec.

## Check that a job fails

Wrap the wait in `raises`:

```lua
assert.raises(function() nv:run_async(job_that_fails):wait() end, 'expected text')
```

## Read several pieces of child state at once

Collect everything you need in one `run`, so the spec makes one round trip:

```lua
local state = nv:run(function()
  return {
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), '\n'),
    events = _G.my_plugin_events or {},
    mode = vim.fn.mode(),
  }
end)
```

## Pass data to the child

Pass values as extra arguments to `run`, and read them with `...`:

```lua
local lines = { 'one', 'two' }
nv:run(function(...)
  local new_lines = ...
  vim.api.nvim_buf_set_lines(0, 0, -1, false, new_lines)
end, lines)
```

To keep state between calls, store it in a child global:

```lua
nv:run(function() _G.events = {} end)
```

## Set the child's environment

Pass `env` to `Nvim.start`:

```lua
nv = Nvim.start { env = { NVIM_TEST = 'true' } }
```

The variables are added to the environment the child inherits. To test the
production path of a plugin that reads such a variable, unset it in the child
before the code under test runs:

```lua
nv:run(function() vim.env.NVIM_TEST = nil end)
```

## Compare a buffer or the screen

Compare lists of lines with `deep_equal`; a failure prints one quoted line per
row, so trailing whitespace shows:

```lua
assert.deep_equal(nv:screen(), {
  'Hello, Ada!                             ',
  -- ...one string per row, the status and command lines included
})
```

To check one row without spelling out the padding, use a pattern:

```lua
assert.matches(nv:screen()[1], '^Hello, Ada!%s*$')
```

## Check an error

Pass the function to `raises`, with text the error must contain:

```lua
local err = assert.raises(function() parse '' end, 'empty input')
assert.matches(err, ':%d+: empty input$')
```

`raises` returns the error, so you can make further checks on it. The text is a
plain substring; use `matches` when you need a pattern.

## Write a plugin-specific assertion

Build it on `deep_equal`, and put it in your plugin's own `_test` directory:

```lua
local function assert_tags(got, want)
  assert.deep_equal(got, want, 'tags differ')
end
```

A failure reports the line inside `assert_tags`, not the line that called it.
