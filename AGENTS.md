# test.nvim - Agent Development Guide

## Project

Shared test helpers for Neovim plugin specs:

- **`lua/test/assert.lua`** — `diff` (a self-contained Levenshtein line diff) and
  `deep_equal`.
- **`lua/test/nvim.lua`** — child-Neovim RPC harness. `Nvim.start` spawns
  `nvim --headless --embed -n -u NORC`; the handle supports `request`, `notify`,
  `run`, `run_async`, `input`, `screen`, `assert_screenshot`, `drain`,
  `wait_until`, and `stop`.
- **`lua/test/init.lua`** — `with_buf`, a host-side temporary-window fixture.

The modules come from the `_test` directories of tuis.nvim and morph.nvim. Those
copies still exist and are still canonical for those plugins. This repository is
the shared home they can migrate to; do not remove their copies as part of work
here.

The repository is a library, not a plugin; it is meant to be vendored. It must
not require tuis.nvim or morph.nvim, and it must not know a plugin's data shapes.
A helper whose parameters name a plugin's data (a morph element, a tag, an
`{ id, text }` event, a buffer watcher) belongs in that plugin's `_test`
directory. `wait_until` and `run` are the general primitives those helpers are
built from.

## Commands

All tasks use `mise`:

- `mise run fmt` — format with stylua
- `mise run fmt:check` — check formatting
- `mise run lint` — type-check with `emmylua_check` (warnings are errors)
- `mise run test` — run busted on Neovim 0.12.5's LuaJIT
- `mise run test:coverage` — test with luacov
- `mise run ci` — `fmt:check` → `lint` → `test`

Run one spec directly after preparing the test dependencies:

```sh
mise run test:prepare
mise exec -- busted spec/nvim_spec.lua
```

## Architecture

- **`lua/test/assert.lua`** — deep equality and a line diff; the diff builds one
  Levenshtein DP table and walks it back in `edit_ops`.
- **`lua/test/nvim.lua`** — child process lifecycle, RPC wrappers, synchronous
  `run` and asynchronous `run_async`, screen capture, screenshot assertions,
  scheduled-work `drain`, and predicate polling with `wait_until`.
- **`lua/test/init.lua`** — `with_buf`, the host-side temporary-window fixture.
- **`spec/assert_spec.lua`** — insertion, deletion, replacement, deep equality,
  and mismatch output.
- **`spec/init_spec.lua`** — temporary-buffer cleanup, initial lines, and
  swapfile isolation.
- **`spec/nvim_spec.lua`** — child start/stop, sync and async runs, input, screen
  dimensions, screenshot matching and mismatch, drain, and `wait_until` success
  and timeout.
- **`library/busted`** — a git submodule of LuaCATS/busted, providing busted type
  stubs for the Lua language server (stylua-ignored). Initialize it after cloning
  with `git submodule update --init --recursive`.

## Test environment

The outer suite runs host-side under busted on Neovim's LuaJIT. The `nvim` spec
then starts its own child `nvim --headless --embed` and drives it over RPC. That
child has a real event loop: input, autocmds, and scheduled callbacks behave as
they do interactively, unlike the host busted runner.

Two rules follow from the RPC boundary:

1. A function passed to `run` or `run_async` is `string.dump`'d with no
   upvalues. State that must survive between calls belongs in child globals.
2. Effects caused by an input or command are only guaranteed to be visible after
   an RPC round-trip. Read them from a later `run`, `request`, or `screen()`
   call, not from the same chunk that caused them.

## Conventions

- LuaJIT; do **not** use goto.
- Stylua: single quotes, no call parentheses for simple statements, 2-space
  indent, 100-column width, sorted requires.
- `run` is synchronous and returns the function's result. `run_async` passes the
  function a `done` callback and reports to `on_done` in the host.
- `wait_until` polls a child-side predicate and issues one RPC round trip per
  attempt, because the round trip — not an in-child wait — is the child's
  event-loop flush point. The predicate belongs to the caller, so plugin
  conventions stay with the plugin.
- Keep the package boundary: this library must not require tuis.nvim or
  morph.nvim, and it must not depend on a plugin's private modules.
