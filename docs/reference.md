# Reference

## Module `test`

`require 'test'` returns a table with these fields.

| Field | Type | Description |
| --- | --- | --- |
| `Nvim` | `test.Nvim` | The child-Neovim harness class. |
| `assert` | `test.assert` | The assertion namespace. |
| `describe`, `it`, `pending`, `before_all`, `after_all`, `before_each`, `after_each` | functions | The spec API. |

A bundle built with `nvim-bundle build test`, or vendored with
`nvim-bundle install`, returns the same table when required, and runs the
command line when executed with `nvim -l`. A bundle that runs specs must be
built by nvim-bundle 0.4.1 or newer.

## Command line

```text
nvim -l <test.lua> [<path or glob>...] [--exclude <glob>]... [--filter <text>] [--coverage]
                   [--isolate file|case] [-j | --jobs <n>] [--timeout <ms>] [--color] [-h | --help]
```

`<test.lua>` is `lua/test/init.lua` in a checkout, or the vendored file.

| Argument | Description |
| --- | --- |
| a directory | Includes every file under it whose name ends in `_spec.lua`. |
| a file | Includes that file. |
| anything else | A glob, matched with `vim.glob.to_lpeg` against paths relative to the current directory. |
| no paths | The same as `spec`. |
| `--exclude <glob>` | Skips the included paths that match. Repeatable. |
| `--filter <text>` | Runs only the cases whose full name contains `<text>` as a plain substring. A full name is the enclosing `describe` names and the case's name, joined by spaces. |
| `--coverage` | Reports line coverage after the run. See [Coverage](#coverage). |
| `--isolate file` | Runs each file in its own process, several at once. See [Isolation](#isolation). |
| `--isolate case` | Runs each case in its own process, several at once. |
| `-j <n>`, `--jobs <n>` | Runs at most `<n>` processes at once. The default is `vim.uv.available_parallelism()`. Without `--isolate`, implies `--isolate file`. |
| `--timeout <ms>` | Kills an isolated process that writes no event for `<ms>` milliseconds. Requires `--isolate` or `--jobs`, because a case running in this process cannot be stopped. |
| `--color` | Colors the output even when stdout is not a terminal. |
| `-h`, `--help` | Prints the usage and exits. |

Before the run, `lua/?.lua` and `lua/?/init.lua` are prepended to
`package.path`, relative to the current directory.

Every file is loaded and collected first, in sorted order, before any case
runs, as in mocha. A file's top-level code, and the `describe` bodies, have
therefore run for every file by the time the first case runs.

Without `--isolate` or `--jobs`, the cases then run in this process, one file
at a time, in sorted order. Every file therefore shares one `package.loaded`,
as any Lua code in one process does: a module that one file requires is the
same instance in every later file. A spec that needs fresh module state runs
with `--isolate file` or `--isolate case`.

| Exit status | Meaning |
| --- | --- |
| 0 | Every case that ran passed. |
| 1 | A case failed, a file failed to load or collect, or no files matched. |
| 2 | An argument was invalid: an unknown option, a glob that does not parse, an `--isolate` other than `file` or `case`, a `--jobs` or `--timeout` that is not a whole number above 0, or a `--timeout` without `--isolate` or `--jobs`. |

### Output

For each file, the runner prints the file's path, then one line per case:
`✓` for a pass, `✗` for a failure, and `-` with `(pending)` for a pending case.
A case that took longer than 75 ms, counting its `before_each` and `after_each`
hooks, has its time after its name, such as `✓ loads the index (120ms)`.
After all files, it prints each failure's full name and error, followed by the
error's full traceback. In an isolated run, a
failure is also followed by `output:` and what was printed while it ran, when
anything was. The last line is
`<n> passed, <n> failed, <n> pending in <seconds>s`.

The output is colored when stdout is a terminal, or when `--color` is given:

| Text | Style |
| --- | --- |
| a file's path, and a failure's heading | bold; the heading also red |
| `✓` | green |
| `✗` | red |
| a pending case | yellow |
| a slow case's time | dim |
| a diff's `- ` and `+ ` lines | red and green |
| a diff's `--- got` and `+++ want` headers | dim |
| a non-zero count in the last line | green for passed, red for failed, yellow for pending |
| a coverage share | green when every line ran, yellow otherwise |
| a coverage row's missed lines | dim |
| a failure's `output:` header | dim |

### Isolation

With `--isolate` or `--jobs`, the cases run in worker processes, and this
process only schedules them and prints the report.

| Rule | Detail |
| --- | --- |
| Collection | This process loads and collects every file first. It applies `--filter`, and it gives every case an id, which is the case's place in its file's collection order. |
| Determinism | Each worker collects its file again and runs the cases by id. Collection must therefore build the same tree in every process: the cases a file declares, their order, and their names must not depend on time, randomness, the environment, a directory listing's order, `pairs()` order, or what an earlier process left on disk. Nothing checks this: a worker that collects a different tree runs other cases, which the report shows under the parent's names. |
| Units | `--isolate file` starts one worker per file, with every selected case. `--isolate case` starts one worker per selected case, pending cases included. |
| Workers | A worker is the same `nvim` binary, started with the flags that came before `-l` in this process, running the same `<test.lua>` with `--worker <dir>`, where `<dir>` holds its job. It inherits this process's environment and current directory. |
| Hooks | `before_all` and `after_all` run once per scope in each worker. Under `--isolate case`, that is once per case, and an `after_all` that raises is reported once per case. |
| Order | A file's report prints once that file and every file before it have finished, so the report reads in sorted order, as in a run in one process. |
| Output | A worker's stdout and stderr go to one file, so `print` (stderr under `nvim -l`) and `io.write` (stdout) keep the order they ran in. A failure shows the bytes written since the worker's previous event, as written: for a failing case, from its start; for a case failed by a `before_all`, the `before_all`'s output. `print` writes its newline before the next message, so a case's output can open with the newline of the previous case's `print`. Passing cases show nothing. |
| A worker that dies | A worker that exits with a signal, exits with a nonzero code, or exits before reporting every case fails the case it was running, with the reason and the worker's output. When no case was running, e.g. in a `before_all`, or when the file failed to load in the worker, the file fails under its own name instead. Every case the worker was given and never reported fails with `did not run: <reason>`. To give every case its own result regardless, use `--isolate case`. |
| Timeout | With `--timeout <ms>`, a worker that writes no event for `<ms>` is killed, and the case it was running fails with `timed out: the worker wrote nothing for <ms> ms`. A worker writes an event as each case starts and as each ends, so the limit applies to each case with its `before_each` and `after_each` hooks, and to the time spent loading the file and in `before_all` hooks. |
| Cleanup | Each worker runs in its own process group. When a worker exits, the whole group is killed, so a process a spec started and left running does not outlive its worker. When this process exits on a signal, it kills the groups of the workers still running. A process that starts its own session or group escapes this. Process groups are a POSIX mechanism, so cleanup is untested on Windows. |
| Coverage | `--coverage` records each worker into the run. A worker killed by `--timeout` or a signal contributes nothing. |

Reasons a worker's case fails:

| Reason | Cause |
| --- | --- |
| `the worker was killed by signal <n>` | The worker crashed, e.g. `11` for a segmentation fault. |
| `the worker exited with code <n>` | The worker exited early, e.g. through `os.exit`, including `os.exit(0)`. |
| `timed out: the worker wrote nothing for <ms> ms` | `--timeout` elapsed. |

### Coverage

With `--coverage`, the run records every line that executes, in the host, in
every child that `Nvim.start` starts, and in every script that `Nvim.script`
runs, and prints a report after the summary:

```text
Coverage
  lua/mod/init.lua   88.9%  8/9  missed: 4
  total              88.9%  8/9
```

| Rule | Detail |
| --- | --- |
| Files reported | Every `lua/**/*.lua` file under the current directory, except paths containing `/vendor/` and type stubs, i.e., files whose first line is `---@meta`. A file that never loaded is reported with its lines missed. |
| Lines counted | Every line that holds a bytecode instruction, in the main chunk and in every nested function. A function's closing `end` line holds the instruction that creates the function, so it counts as run whenever the definition runs. |
| Child and script lines | `Nvim.start` and `Nvim.script` install the line hook with `--cmd`, so the hook is in place before any of the plugin's code, or a script's first line, can run. The process writes its lines to a file in a temporary directory when it exits, whether it is stopped, returns, or calls `os.exit`, and the report reads them when the run ends. A process that crashes, is killed, or is still running when the run ends contributes nothing. A measured process also measures the processes it starts with `Nvim.start` and `Nvim.script`, such as an isolated worker's child editors. |
| Disabled lines | Lines after a `-- luacov: disable` line are not counted, until a `-- luacov: enable` line or the end of the file. A marker must be the whole line, apart from indentation. The scan reads lines, not Lua, so a line inside a multi-line string that is exactly a marker also counts as one. |
| Exit status | Unaffected; coverage does not fail a run. |

Recording slows every line that runs, so a coverage run is slower than a plain
one.

## Spec API

A spec file declares its cases when it loads. Each function below raises
`<name>: no spec run is active` when it is called outside a run.

### `describe(name, fn)`

Opens a scope named `name` and calls `fn` immediately, collecting the cases and
hooks it declares. Scopes nest. An error raised by `fn` fails the whole file,
and none of the file's cases run.

### `it(name, fn)`

Declares a case. `fn` runs after the whole file has been collected. Raises when
`fn` is not a function.

### `pending(name)`

Declares a case that is reported as pending and not run.

### `before_all(fn)` and `after_all(fn)`

Register a hook that runs once per scope: `before_all` before the first
selected case in the scope, nested scopes included, and `after_all` after the
last one. Called outside any `describe`, they apply to the whole file. A scope
in which `--filter` selects no case runs neither hook.

When a `before_all` raises, the scope's remaining `before_all` hooks and all
of its cases are skipped, and each selected case is reported as failed with
`before_all in <scope> failed:` and the error. The scope's `after_all` hooks
still run. An `after_all` that raises is reported as a failure named
`<scope> (after_all)`.

### `before_each(fn)` and `after_each(fn)`

Register a hook on the current scope, which is the file itself when called
outside any `describe`. For each case, the `before_each` hooks of its enclosing
scopes run from the outermost scope inward, in the order they were declared.
If one raises, the rest and the case itself are skipped. The `after_each`
hooks then run from the innermost scope outward, always. Every error that a
case or its hooks raise is reported with the case.

A case also fails when Neovim reported an error during it without raising
one, i.e. when `v:errmsg` is set once the case and its hooks have run. Before
that check, the callbacks the case scheduled with `vim.schedule` run, so their
errors count against the case that scheduled them. The failure reads
`Neovim reported an error the case did not raise:` followed by the message.
An error that `pcall` catches does not set `v:errmsg`, so a case that raises
an error on purpose and catches it still passes. A case that reports an error
on purpose, e.g. with `vim.notify` at `ERROR` level, passes when it clears
`vim.v.errmsg` afterward.

## Class `test.Nvim`

### `Nvim.start(opts?)`

Starts a child Neovim and returns its handle, a `test.Nvim`.

The child runs `nvim --headless --embed -n -u NORC` with RPC over stdio, using
the same `nvim` binary as the host (`vim.v.progpath`). `start` then appends `opts.rtp` to the
child's runtimepath with `set rtp+=`, and returns once the child has answered.
Startup has already finished at that point, so the appended directory's
`plugin/` files are not sourced. The child also starts with `'more'` off,
because output that runs past its screen would otherwise stop at a
`-- More --` prompt that nothing answers.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `columns` | `integer?` | the child's default | Sets `columns` with `--cmd` before startup. |
| `rows` | `integer?` | the child's default | Sets `lines` with `--cmd` before startup. |
| `rtp` | `string?` | `vim.fn.getcwd()` | The directory appended to the child's runtimepath. |
| `env` | `table<string, string>?` | none | Variables added to the environment the child inherits. |

Raises `jobstart failed: <code>` when the process cannot start, and a channel
error when the child exits before it answers.

### `Nvim.script(path, args?, opts?)`

Runs `nvim -l <path> <args...>` as a plain process, waits for it to exit, and
returns its `vim.SystemCompleted`. Use it for a script that writes to stdout or
sets its exit status, which an `Nvim.start` child cannot do because its stdio
carries RPC.

The process uses the same `nvim` binary as the host (`vim.v.progpath`). `-l`
already skips the user's config, plugins, and shada, so no other flags are
added.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `path` | `string` | required | The script, relative to `opts.cwd` or to the host's current directory. |
| `args` | `string[]?` | none | The script's `arg[1]`, `arg[2]`, and so on. |
| `opts` | `vim.SystemOpts?` | `{ text = true }` | Passed to `vim.system`; `text` is true unless `opts` sets it. |

### `nv:stop()`

Closes the child's channel, and waits for the child to exit. A child that has
not exited after 2000 ms, such as one stuck in a busy loop, is killed. Calling
it more than once is safe.

Before closing the channel, `stop` reads the child's `v:errmsg`, and once the
child is gone it raises `the child reported an error: <message>` when it is
set. So a callback that raised after the last `run` still fails the case that
calls `stop`, usually from an `after_each`.

### `nv:request(method, ...)`

Calls the API function `method` in the child with `vim.rpcrequest`, blocks
until it answers, and returns its result.

### `nv:notify(method, ...)`

Calls the API function `method` in the child with `vim.rpcnotify`, and returns
immediately.

### `nv:run(f, ...)`

Runs `f(...)` in the child and returns its result.

`f` is serialized with `string.dump`, so it keeps no upvalues. The extra
arguments and the result cross the RPC boundary as msgpack, so they must be
values msgpack can carry; a `nil` result arrives as `vim.NIL`, which
`assert.is_nil` accepts. An error in `f`
raises in the host.

`run` also raises `the child reported an error: <message>` when an error was
reported in the child without being raised: one from a callback `f`
triggered, such as an autocmd, or from a callback that ran since the previous
`run`, such as a `WinScrolled` callback after `nv:input`. Each such error is
reported once.

### `nv:run_async(f)`

Starts `f(done)` in the child, returns a `test.Pending` immediately, and does
not block.

`f` is serialized as for `run`. The first call to `done(value)` settles the
pending result with `value`; later calls are ignored. An error that `f` raises
before calling `done` settles the result as failed, with that error.

### `nv:input(keys)`

Translates `keys` from key notation with `nvim_replace_termcodes`, sends the
result through `nvim_input`, and returns the number of bytes written.

### `nv:screen()`

Runs `redraw!` in the child, reads every cell with `screenstring`, and returns
a `string[]` with one string per row. The list includes the status and command
lines, so its length is the child's `lines`.

### `nv:drain(timeout_ms?)`

Waits until the work already queued in the child with `vim.schedule` has run.
It schedules a callback behind that work and waits for it as a `run_async` job,
so it raises the same timeout error as `Pending:wait`. The default timeout is
2000 ms.

### `nv:wait_until(pred, timeout_ms?, msg?)`

Runs `pred` in the child, one RPC round trip per attempt with a 10 ms pause
between attempts, until it returns a truthy value. `pred` is serialized as for
`run`.

Raises `msg` when `timeout_ms` (default 2000) passes, or
`wait_until: the predicate did not hold within <timeout_ms> ms` when no message
is given.

## Class `test.Pending`

The result of one `run_async` job. It settles once, with either a value or an
error.

### `p:wait(timeout_ms?)`

Blocks until the job settles, and returns its value. The host's event loop runs
while it waits.

Raises `run_async: the child raised: <error>` when the job failed, and
`run_async: no result after <timeout_ms> ms` when the job has not settled
within `timeout_ms` (default 2000).

### `p:on_settled(cb)`

Calls `cb(ok, value)` once the job settles, and returns immediately. `ok` is
`false` when the job failed, and `value` is then its error.

When the job has already settled, `cb` runs on a later tick. Otherwise it runs
when the host handles the child's result, which happens only while the host's
event loop runs, i.e., inside `vim.wait`. An error raised by `cb` does not
propagate to the spec.

## Namespace `test.assert`

Each assertion returns when its check holds, and otherwise raises an error at
its caller's level, so the error names the line that called the assertion.

### Failure format

Every failure has three parts:

1. a first line, `<name> failed`, with `: <msg>` appended when `msg` is given;
2. a line saying what was expected, which names both types when they differ;
3. the shortest line diff of two values, `got` and `want`, headed by
   `--- got` and `+++ want`.

In the diff, an unchanged line is prefixed with two spaces, a `got` line with
`- `, and a `want` line with `+ `; a replaced line appears as `-` then `+`. A
string, and a non-empty list of strings, print one `vim.inspect`-quoted entry
per line. Every other value prints as the lines of `vim.inspect`.

```text
spec/prompt_spec.lua:12: deep_equal failed: buffer
expected equal contents
--- got
+++ want
  "local x = 1"
- "print(x) "
+ "print(x)"
```

### Assertions

| Call | Passes when | Returns | Diff (`got` / `want`) |
| --- | --- | --- | --- |
| `assert(value, msg?)` | `value` is truthy | `value` | `value` / `true` |
| `assert.ok(value, msg?)` | `value` is truthy | `value` | `value` / `true` |
| `assert.is_nil(value, msg?)` | `value` is `nil` or `vim.NIL` | — | `value` / `nil` |
| `assert.equal(got, want, msg?)` | `got == want` | — | `got` / `want` |
| `assert.not_equal(got, want, msg?)` | `got ~= want` | — | `got` / `want` |
| `assert.deep_equal(got, want, msg?)` | `vim.deep_equal(got, want)` | — | `got` / `want` |
| `assert.not_deep_equal(got, want, msg?)` | not `vim.deep_equal(got, want)` | — | `got` / `want` |
| `assert.contains(haystack, needle, msg?)` | the string `haystack` holds `needle` as a plain substring, or the list `haystack` holds an element deep-equal to `needle` | — | `haystack` / `needle` |
| `assert.matches(str, pattern, msg?)` | `str:find(pattern)` | — | `str` / `pattern` |
| `assert.raises(fn, expected?, msg?)` | `fn()` raises, and its error holds `expected` as a plain substring when `expected` is given | the error | the values `fn` returned / `expected` or `"an error"`, or the error / `expected` |

`equal` compares tables by identity. When `got` and `want` are different but
deep-equal tables, its note says so.

`raises` checks a non-string error against `expected` through `vim.inspect`.

### Misuse errors

These errors report a wrong argument, not a failed check.

| Call | Error |
| --- | --- |
| `contains` with a haystack that is neither a string nor a table | `contains: haystack must be a string or a list, got <type>` |
| `contains` with a string haystack and a non-string needle | `contains: a string haystack needs a string needle, got <type>` |
| `matches` with a non-string `str` | `matches: str must be a string, got <type>` |
