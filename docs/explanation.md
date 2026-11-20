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

## Why a case fails on an error Neovim only reported

Neovim does not pass every error to the code that caused it. An example of
this is an autocmd whose callback raises:

1. A case calls `nvim_exec_autocmds`, and the callback raises.
2. Neovim prints the error and stores it in `v:errmsg`.
3. `nvim_exec_autocmds` returns normally, so the case sees no error.

The case would therefore pass while the output shows an error. The same holds
for a callback the case schedules with `vim.schedule`, which runs after the
case returns, and for any callback in a child Neovim, whose errors stay in the
child. So the runner checks `v:errmsg` after each case, after running the
callbacks the case scheduled, and `run` and `stop` check the child's. An error
that `pcall` catches leaves `v:errmsg` alone, which is why a case can still
test errors on purpose.

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
its own child editor, so child-side state cannot leak between cases. The
runner leaves host-side state alone: a module's cache lives as long as its
process, as it does anywhere in Lua, and a spec that needs fresh host state
asks for a process of its own with `--isolate`.
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
the host alone would report it as never run. A plugin's `nvim -l` script is a
third place code runs.

Every such process gets its lines back to the host in one way. `Nvim.start`
and `Nvim.script` install the same hook with `--cmd`, before any of the
plugin's code can load, and the process writes its lines to a file in the
run's directory as it exits. A child exits when `Nvim:stop()` closes its
channel, and `Nvim:stop()` waits for that exit, so the file is complete
before the run reads it. A script usually sets its exit status with
`os.exit`, which skips `VimLeavePre`, so the hook also wraps `os.exit` to
write the file first. When the run ends, the report combines the host's lines
and every file's lines per file.

A child's RPC channel could carry its lines back instead, but a script has no
such channel. One way back for both means one path to install the hook, one
to collect the lines, and one failure rule: a process that crashes loses its
lines.

Every line that holds an instruction counts, with no exceptions. A function
that ends in `error(...)` looks like it needs one: its closing `end` holds a
return instruction that can never run. LuaJIT, however, also puts the
instruction that creates the function on that line, in the enclosing
function, so the line runs whenever the definition does, and it never shows
as missed for a function that was defined.

## Why isolated workers report through files

A run in one process -- under normal circumstances, the default -- cannot
survive its own death. An example of this is a case that dereferences a null
pointer through the FFI: the signal kills the runner, so the summary, with
every failure's message, is never printed. `--isolate` moves the cases into
worker processes, so that a death costs one case instead of the run, and so
that workers can run in parallel.

A worker writes everything the parent needs into two files. The first holds
one JSON line per event: a case started, passed, failed, or is pending. The
worker flushes each line, so a worker that crashes has still reported
everything before the crash. The second file is the worker's stdout and its
stderr at once. Both descriptors point at one file, so every writer moves one
offset: `print`, `io.write`, and any process a spec starts. Each event records
that offset, so the bytes between two events are what ran between them.

The obvious alternatives each break one of those properties:

1. An RPC channel, as with `Nvim.start`, uses stdout as its transport, so a
   spec's `io.write` would corrupt it.
2. Events framed inside stdout lose their order relative to `print`, because
   `print` under `nvim -l` writes to stderr, and a pipe cannot join the two
   streams in order.
3. A pipe on a third descriptor needs its own spawn plumbing, and every
   process a spec starts inherits it.

So a crash is diagnosed from the files alone. The parent reads the last case
that started without finishing, i.e., the case that was running when the
worker died, and fails it with the signal or the exit code. Every case the
worker never reported fails with `did not run`: those cases shared the
process that died, and isolating them from each other is what
`--isolate case` is for.

The worker itself runs cases exactly as a run in one process does. There is
one way to run cases, the in-process executor, and `--isolate` only changes
where it runs: the spawner splits the suite into jobs, and each worker runs
its job with the in-process executor, writing each event as a line instead of
printing it. Both executors emit the same events, in file order, so one
report consumes either.

The parent collects every file itself, before any worker starts. It then owns
the names, the filter, and the ids, and it hands each worker only ids. This is
what makes determinism a requirement: a worker that collects a different tree
runs different cases under the same ids, and the parent reports them under the
names from its own tree. Nothing detects the mismatch, so the requirement is
the spec author's to keep.

`--timeout` measures progress, not duration. The parent arms a timer for
`<ms>` after the events file last changed, and it kills the worker only when that timer
fires with no newer event. That is the same as a per-case limit, because a
worker writes an event as each case starts and ends, and it needs no polling
interval to tune.

Each worker leads its own process group, and the parent kills the whole group
whenever a worker exits. A spec that starts a process and forgets it, or a
case killed mid-way, then leaves nothing running. The cost is that a
terminal's Ctrl-C no longer reaches the workers directly, so the parent kills
the groups itself when it dies on a signal.

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
