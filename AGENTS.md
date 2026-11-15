# test.nvim - Agent Development Guide

## Project

Shared test helpers for Neovim plugin specs:

- **`lua/test/nvim.lua`** — child-Neovim RPC harness. `Nvim.start` spawns
  `nvim --headless --embed -n -u NORC`; the handle supports `request`, `notify`,
  `run`, `run_async` (which returns a `test.Pending` with `wait` and
  `on_settled`), `input`, `screen`, `drain`, `wait_until`, and `stop`.
- **`lua/test/assert.lua`** — Node-style assertions in one callable namespace:
  `ok`, `is_nil`, `equal`, `not_equal`, `deep_equal`, `not_deep_equal`,
  `contains`, `matches`, and `raises`. Every failure prints the shortest line
  diff of two values, built from a Levenshtein table without replacement.
- **`lua/test/runner.lua`** — the spec API (`describe`, `it`, `pending`,
  `before_all`, `after_all`, `before_each`, `after_each`) and the runner that
  collects and runs it.
- **`lua/test/coverage.lua`** — `--coverage`: line hooks in the host and every
  child, and the per-file report.
- **`lua/test/color.lua`** — ANSI styling, on for a terminal or with `--color`.
- **`lua/test/cli.lua`** — the `nvim -l` command line: argument parsing,
  spec discovery with `vim.glob`, and the exit status.
- **`lua/test/vendor/args.lua`** — argument parser vendored by
  `nvim-bundle install jrop/args.nvim args` and recorded in
  `nvim-bundle.json`. Do not edit it; rerun `nvim-bundle install` instead.
- **`lua/test/init.lua`** — the library's one public surface,
  `{ Nvim, assert, describe, it, pending, before_all, after_all, before_each,
  after_each }`. Executed
  as `nvim -l lua/test/init.lua`, it runs the command line instead.
- **`docs/`** — user documentation in the four Diátaxis forms: `tutorial.md`,
  `how-to.md`, `reference.md`, and `explanation.md`. `README.md` is a landing
  page that links to them. Keep each document to its one job: steps a learner
  can follow in the tutorial, tasks in the how-to guides, facts in the
  reference, and reasons in the explanation. A change to the API updates the
  reference, and every other document that shows the changed call.

Consumers reach every helper through `require 'test'`. The release bundle
(`nvim-bundle build test`) returns only that module, so the other files are
implementation; a new public helper must be exported from `init.lua`, and
`spec/api_spec.lua` lists the surface.

The modules come from the `_test` directories of tuis.nvim and morph.nvim. Those
copies still exist and are still canonical for those plugins. This repository is
the shared home they can migrate to; do not remove their copies as part of work
here.

The repository is a library, not a plugin; it is meant to be vendored. It must
not require tuis.nvim or morph.nvim, and it must not know a plugin's data shapes.
A helper whose parameters name a plugin's data (a morph element, a tag, an
`{ id, text }` event, a buffer watcher) belongs in that plugin's `_test`
directory. `run`, `wait_until`, and `assert.deep_equal` are the general
primitives those helpers are built from.

## Commands

All tasks use `mise`:

- `mise run fmt` — format with stylua
- `mise run fmt:check` — check formatting
- `mise run lint` — type-check with `emmylua_check` (warnings are errors)
- `mise run test` — run the specs with the library's own runner
- `mise run test:coverage` — the same, with a line-coverage report
- `mise run ci` — `fmt:check` → `lint` → `test`

`mise.toml`'s `[env]` sets `VIMRUNTIME`, which `.emmyrc.json` loads as a type
library; an editor sets it for its language server, but a shell does not.

Run one spec file, or part of one, directly:

```sh
nvim -u NONE -i NONE -l lua/test/init.lua spec/nvim_spec.lua
nvim -u NONE -i NONE -l lua/test/init.lua --filter 'run_async'
```

## Architecture

- **`lua/test/nvim.lua`** — child process lifecycle, RPC wrappers, synchronous
  `run`, asynchronous `run_async` and its `test.Pending` result, screen
  capture, scheduled-work `drain` (an async job), and predicate polling with
  `wait_until`. Waits raise on timeout rather than returning false.
- **`lua/test/assert.lua`** — the assertions and their private line diff. Every
  failure goes through one `fail(name, msg, note, got, want)`, so each prints a
  header, a note, and a diff of two values. The diff builds a Levenshtein
  table without replacement, over suffixes, and walks it forward. Strings and
  lists of strings print one quoted entry per line, because `vim.inspect`
  prints a list on one line.
- **`lua/test/runner.lua`** — the tree of scopes and cases, built while a spec
  file loads, and the run: hooks outer to inner before a case and inner to
  outer after it, the module reset after each file, and the `Report` that
  counts each outcome and prints it in the same step. The collecting scope is
  a module local.
- **`lua/test/coverage.lua`** — hits recorded by one line-hook function,
  `record_lines`, which runs in the host and, through `Nvim:run` at start, in
  every child; `Nvim:stop()` reads a child's hits back. Executable lines come
  from `jit.util` bytecode walks, without a function's implicit closing `RET0`.
  The recording flag is a module local; the hits live in the global
  `__test_coverage_hits` in each process, because `record_lines` also runs in
  children, which do not load the library.
- **`lua/test/cli.lua`** — argument parsing, spec discovery, the color
  decision (`vim.uv.guess_handle(1) == 'tty'`, or `--color`), exit status, and
  `running()`, which is true while `main` runs.
- **`lua/test/init.lua`** — the public surface, and the script entry. Run as
  the script, it hands off to `test.cli` before loading the other modules; the
  CLI starts coverage and then requires the runner, so the library's own
  modules are recorded from their first line. A spec that requires the
  running file executes this entry again. Every other module is shared between
  the two executions: a checkout's requires hit `package.loaded`, and a bundle
  built by nvim-bundle 0.4.1 or newer keeps one module cache per file. So
  module state lives in plain locals, and the entry alone must tell the two
  executions apart: it reads the plain `arg`, which a bundle empties on the
  second execution, and asks `cli.running()`, which covers a checkout.
- **`spec/api_spec.lua`** — the exported names of `test`, `test.assert`, and
  `test.Nvim`.
- **`spec/runner_spec.lua`** — the runner and command line, checked from
  outside: each case writes a spec project to a temporary directory and runs
  the CLI on it in a separate `nvim -l`. Those runs write to a pipe, so their
  output is plain unless the case passes `--color`.
- **`spec/assert_spec.lua`** — each assertion's pass and fail cases, failure
  output (including the diff's insertion, deletion, replacement, and
  shortest-diff choice), and the error level that names the spec's line.
- **`spec/nvim_spec.lua`** — child start/stop and `env`, sync runs, async jobs
  (`wait`, concurrency, errors, timeout, `on_settled`), input, screen, drain,
  and `wait_until` success and timeout.

## Test environment

The outer suite runs host-side under the library's own runner, on Neovim's
LuaJIT. The `nvim` spec then starts its own child `nvim --headless --embed` and
drives it over RPC. That child has a real event loop: input, autocmds, and
scheduled callbacks behave as they do interactively, unlike the host process
running the specs.

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
  function a `done` callback and returns a `test.Pending`; `wait` blocks for the
  value, and `on_settled` calls back without blocking. The child reports with
  `vim.rpcnotify`, and an error raised before `done` settles the job.
- Specs use explicit locals (`local describe, it = Test.describe, Test.it`),
  never injected globals.
- `spec/assert_spec.lua` checks `test.assert` with Lua's built-in `assert` and
  local helpers, not with `test.assert`, so a bug in the assertions cannot hide
  itself.
- `wait_until` polls a child-side predicate and issues one RPC round trip per
  attempt, because the round trip — not an in-child wait — is the child's
  event-loop flush point. The predicate belongs to the caller, so plugin
  conventions stay with the plugin.
- Keep the package boundary: this library must not require tuis.nvim or
  morph.nvim, and it must not depend on a plugin's private modules.
