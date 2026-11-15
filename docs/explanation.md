# Explanation

This document explains why test.nvim is shaped the way it is. It describes the
constraints the design follows from, and the alternatives it rejected.

## Why specs drive a second Neovim

A plugin's behavior usually depends on the editor running around it. An example
is a plugin that reacts to typing: it needs a real event loop, autocmds such as
`TextChanged` that fire from real input, and a screen that is actually drawn.
The process running the specs has none of these in the form a user's editor
does, because it is busy running the specs.

The library therefore starts a second Neovim as a child process, and the spec
drives it over RPC. The plugin then runs in an editor that behaves as it does
interactively, i.e., input is typed, autocmds fire, and the screen is redrawn,
while the spec watches from outside.

## The two rules the RPC boundary imposes

The host and the child are separate Lua states, and two rules follow from that.

**A function sent to the child keeps its code but not its variables.** The
library sends a function across with `string.dump`, which serializes the
function's code and drops its upvalues. An example is a spec that sets
`local name = 'Ada'` and sends a function using `name`: in the child, `name`
is `nil`. So data a function needs arrives as an argument, and state that must
last between calls lives in a child global.

**An effect is visible only in a later round trip.** When the host sends a
request, the child handles it, runs its event loop, and answers. An effect that
a request causes, such as the mode change from `:startinsert` or a
`vim.schedule` callback, happens after that request's own code has run. So the
spec reads the effect in a later call, and the round trip is the point at which
the child's pending work gets to run.

The API's shape follows from these rules. `run` makes one round trip.
`wait_until` makes as many round trips as a condition needs, because each one
lets the child make progress. `drain` waits for the work queued so far. Each
of them checks the child's state from outside, after the child has had a chance
to change it.

## Why every wait raises

`drain`, `wait_until`, and `Pending:wait` all raise when they run out of time,
instead of returning `false`.

A wait that returns `false` relies on every caller to check the result. An
example is a spec that waits for a plugin to finish and then compares the
buffer: when the wait times out silently, the comparison runs on stale state
and fails with a confusing diff, far from the actual cause. A wait that raises
stops the spec at the line that waited, with a message saying what never
happened.

## Why async work returns a pending result

Sync and async use only differ in when the host waits; the child runs the
function the same way either time. So `run_async` returns a `test.Pending`, and
the spec chooses when to wait on it:

- `p:wait()` blocks, so `nv:run_async(f):wait()` is the synchronous form.
- Starting several jobs before waiting on any runs them concurrently in the
  child.
- `p:on_settled(cb)` calls back without blocking.

The result carries either a value or an error. An example of why that matters
is a job that raises before it calls `done`: the error settles the result, so
`wait` raises it, instead of timing out with no hint of the cause.

The child reports its result with a notification, not a request. A request
would block the child until the host answers, and the host answers only while
its own event loop runs. A notification lets the child send the result and
continue.

## Why the assertions are flat functions in one namespace

The assertions are plain functions, as in Node's `assert` module, rather than a
chain such as `expect(x):to_equal(y)`.

An expect object only repackages its value. Each of its methods passes the
wrapped value to a check that could have taken the value as its first argument,
so the object adds a concept without adding behavior. In Lua, a chain also
invites two mistakes: `expect(x).equals(y)` in place of `:equals` fails with a
confusing `self` error, and negation cannot be called `not`, because `not` is a
keyword.

The assertions live in a namespace, `assert.*`, rather than under a prefix such
as `assert_*`, because a namespace is how Node signals that a call is an
assertion. A spec can then shadow Lua's built-in with
`local assert = Test.assert`, and the namespace is callable so that
`assert(value, msg)` keeps working after the shadowing. Most names keep
luassert's meaning, which eases a move from busted; for example, `equal`
checks identity and `matches` takes a Lua pattern.

## Why every failure prints a diff

A failure should show what differs, not only that something does. So every
assertion compares two values, and every failure prints the same three parts:
a header, a note, and a diff of the two values. Even an assertion without an
obvious second value gets one; an example is `ok`, which diffs the value
against `true`.

Lists of strings print one entry per line, because `vim.inspect` prints a list
on a single line. An example is a 30-line buffer: through `vim.inspect`, it
would print as one long `-` line and one long `+` line. One entry per line,
quoted, shows exactly which lines changed, including trailing whitespace.

The diff is the shortest possible. It is computed as Levenshtein distance
without the replace move, because a replaced line prints as a `-` line plus a
`+` line, i.e., it costs two lines of output, not one. With a replace move, the
table would score scripts that print more lines than necessary as optimal.

## Why `is_nil` accepts `vim.NIL`

A value crosses the RPC boundary as msgpack, and msgpack carries nil as a
value. A Lua table cannot hold `nil`, so Neovim represents that value as
`vim.NIL`. An example is `nv:run(function() return nil end)`, which returns
`vim.NIL` in the host. The two mean the same thing to a spec, so `is_nil`
accepts both, while `equal` and `deep_equal` keep them distinct.

## Why the library runs its own specs

A plugin's specs need Neovim to run, and the library already starts Neovim.
busted, by contrast, needs a whole toolchain beside it: a standalone Lua 5.1
for luarocks, luarocks itself, busted and luassert, and search paths that let
Neovim's LuaJIT find them. An example of that toolchain's cost is CI: building
Lua 5.1 from source needs system headers that a stock runner lacks. A runner
inside the library replaces all of it with `nvim -l`.

The runner can stay small because the rest of the library already does the
hard parts. Assertions report a failure by raising an error that already holds
a diff, so the runner only catches errors and prints them. Each case starts
its own child editor, so child-side state cannot leak between cases; the
runner only resets the host side, by dropping the modules each file loaded.
And waits block on `vim.wait`, which keeps the host's event loop running, so
async work needs nothing from the runner.

The spec API is explicit locals, `local describe, it = Test.describe, Test.it`,
rather than injected globals. A reader can then see where every name in a spec
comes from, and the type checker knows each name's signature without a stub
library.

## How coverage works without luacov

Coverage needs two numbers per file: the lines that ran, and the lines that
could have. Both are available inside Neovim's LuaJIT. A line hook,
`debug.sethook(fn, 'l')`, sees every line that runs, even in JIT-compiled
code. `jit.util` exposes each function's bytecode with its line numbers, so
the lines that hold code are the lines some instruction belongs to.

LuaJIT's built-in profiler, `jit.profile`, cannot do this job: it samples,
so a function that runs once, but briefly, never appears.

The part that shapes the design is where the code runs. A plugin's code mostly
runs in the child editors, not in the process running the specs, so a hook in
the host alone would report it as never run. Each child therefore installs the
same hook as it starts, and `Nvim:stop()` reads the child's lines back before
stopping it. The report merges the host's lines with every child's.

One rule keeps the numbers honest. A function that ends in `error(...)` still
gets an implicit return instruction on its closing `end`, and that instruction
can never run, so the line would always show as missed. The report leaves out
a closing `end` whose only instruction is that implicit return; the line
before it already shows whether the function got that far.

## Why the library is one module

A consumer reaches every helper through `require 'test'`. The reason is
vendoring: `nvim-bundle build test` produces one file that returns only the
`test` module, so a path such as `require 'test.nvim'` would not exist in a
vendored copy. The same file is also the command line, because the one thing a
consumer vendors should be everything a consumer needs. The files under `lua/test/` are the implementation, and
`init.lua` is the whole public surface.

## What belongs in the library

The library keeps only helpers that a spec for an unrelated plugin could call
unchanged. A helper whose parameters name one plugin's data, such as a rendered
element, a tag, or an event record, belongs in that plugin's own `_test`
directory, built from `run`, `wait_until`, and `assert.deep_equal`.

For the same reason, the library sets no plugin conventions in the child. An
example is a variable that turns off a plugin's debounce timers in tests: the
spec passes it through `env`, because the variable belongs to the plugin, not
to the library.

## Why there is no buffer fixture

A buffer fixture gives a spec an isolated buffer: it opens a scratch window,
turns off the buffer's swapfile, and cleans up afterward, even when the spec
fails. A fresh child already provides all three. Every spec starts its own
child, the child runs without swapfiles, and `stop()` discards the whole
editor. So a spec that needs a buffer sets the child's lines with one `run`,
and the library has no fixture to learn.
