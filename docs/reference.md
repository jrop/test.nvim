# Reference

## Module `test`

`require 'test'` returns a table with two fields.

| Field | Type | Description |
| --- | --- | --- |
| `Nvim` | `test.Nvim` | The child-Neovim harness class. |
| `assert` | `test.assert` | The assertion namespace. |

A bundle built with `nvim-bundle build test`, or vendored with
`nvim-bundle install`, returns the same table.

## Class `test.Nvim`

### `Nvim.start(opts?)`

Starts a child Neovim and returns its handle, a `test.Nvim`.

The child runs `nvim --headless --embed -n -u NORC` with RPC over stdio, using
the same `nvim` binary as the host. After the child answers
`nvim_get_api_info`, `start` appends `opts.rtp` to the child's runtimepath with
`set rtp+=`. Startup has already finished at that point, so the appended
directory's `plugin/` files are not sourced.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `columns` | `integer?` | the child's default | Sets `columns` with `--cmd` before startup. |
| `rows` | `integer?` | the child's default | Sets `lines` with `--cmd` before startup. |
| `rtp` | `string?` | `vim.fn.getcwd()` | The directory appended to the child's runtimepath. |
| `env` | `table<string, string>?` | none | Variables added to the environment the child inherits. |

Raises `jobstart failed: <code>` when the process cannot start, and
`child nvim never became ready` when the child does not answer within one
second.

### `nv:stop()`

Stops the child. Calling it more than once is safe.

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
