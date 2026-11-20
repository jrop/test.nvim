---@diagnostic disable: global-in-non-module

local coverage = require 'test.coverage'

--- Nvim remote-control helper.
--- Spawns a child `nvim --headless --embed` with RPC on stdio,
--- drives it via msgpack-RPC, and snapshots the screen grid.
---
--- This child is headless but is NOT subject to the limitations of the host
--- process running the specs: it has a real event loop driven by RPC, so `TextChanged`/
--- `TextChangedI` autocmds fire naturally from real input, and programmatic
--- `:startinsert` genuinely enters insert mode. The mode change (and any
--- scheduled work) is only observable across an RPC round-trip (a later `run`/
--- `request`), NOT within the same `run` that issued it - the round-trip is the
--- event-loop flush point. See AGENTS.md's "Test environment" section for the
--- full host/child distinction.

--- @class test.Nvim
--- @field chan integer  the job id, which `rpc = true` also makes the channel id
local Nvim = {}
Nvim.__index = Nvim

--- @class test.NvimStartOpts
--- @field columns? integer
--- @field rows? integer
--- @field rtp? string  appended to the child's runtimepath (default: the cwd)
--- @field env? table<string, string>  added to the child's environment

--- @param opts? test.NvimStartOpts
--- @return test.Nvim
function Nvim.start(opts)
  opts = opts or {}
  --- @cast opts test.NvimStartOpts

  --- @type string[]
  local argv = { vim.v.progpath, unpack(coverage.argv()) }
  vim.list_extend(argv, { '--headless', '--embed', '-n', '-u', 'NORC' })
  -- Output that runs past the screen would stop at a "-- More --" prompt that
  -- nothing answers, and the request that printed it would never return.
  vim.list_extend(argv, { '--cmd', 'set nomore' })
  if opts.columns then
    vim.list_extend(argv, { '--cmd', ('set columns=%d'):format(opts.columns) })
  end
  if opts.rows then vim.list_extend(argv, { '--cmd', ('set lines=%d'):format(opts.rows) }) end

  local chan = vim.fn.jobstart(argv, { rpc = true, env = opts.env })
  if chan <= 0 then error('jobstart failed: ' .. chan, 2) end
  local self = setmetatable({ chan = chan }, Nvim)

  -- No readiness wait is needed: a request sent before the child is ready waits
  -- in the pipe until the child reads it. 100 starts, each followed at once by
  -- a request, all succeeded.

  -- Add repo to child rtp.
  local rtp = opts.rtp or vim.fn.getcwd()
  self:request('nvim_command', 'set rtp+=' .. vim.fn.escape(rtp, ' '))

  return self
end

--- Run `nvim -l <path> <args...>` under the suite's own Neovim, and wait for it
--- to exit. A script that owns its process (its stdout, its exit status) cannot
--- run in an `--embed` child, because the child's stdio is the RPC channel.
--- `-l` already skips the user's config, plugins, and shada, so the command
--- needs no isolating flags.
--- @param path string
--- @param args? string[]  the script's `arg[1]`, `arg[2]`, ...
--- @param opts? vim.SystemOpts  passed to `vim.system`; `text` defaults to true
--- @return vim.SystemCompleted
function Nvim.script(path, args, opts)
  local cmd = { vim.v.progpath, unpack(coverage.argv()) }
  vim.list_extend(cmd, { '-l', path, unpack(args or {}) })
  return vim.system(cmd, vim.tbl_extend('keep', opts or {}, { text = true })):wait()
end

--- @param method string
--- @param ... any
function Nvim:request(method, ...) return vim.rpcrequest(self.chan, method, ...) end

--- @param method string
--- @param ... any
function Nvim:notify(method, ...) vim.rpcnotify(self.chan, method, ...) end

-- What `run` executes in the child. The child reports an error raised in one
-- of its own callbacks as a message instead of passing it back, so the result
-- would look fine. The message lands in v:errmsg, though, so hand it back with
-- the result for the host to raise, and clear it so it is reported once. A
-- callback can also raise between runs, e.g. a WinScrolled callback after
-- `input`, so this is not cleared before the function runs: the next run
-- reports what happened since the last one.
local RUN = [[
local f = ...
local result = assert(loadstring(f))(select(2, ...))
local errmsg = vim.v.errmsg
vim.v.errmsg = ''
if result == nil then result = vim.NIL end
return { result = result, errmsg = errmsg }
]]

--- Run a function inside the child and return its result.
--- The function is serialized via `string.dump` - upvalues are NOT preserved,
--- so pass the data it needs as arguments.
--- @param f fun(...): any
--- @param ... any  arguments forwarded to `f`
--- @return any
function Nvim:run(f, ...)
  local reply = self:request('nvim_exec_lua', RUN, { string.dump(f), ... }) --[[@as { result: any, errmsg: string }]]
  if reply.errmsg ~= '' then error('the child reported an error: ' .. reply.errmsg, 2) end
  return reply.result
end

--------------------------------------------------------------------------------
-- Async jobs
--------------------------------------------------------------------------------

--- The result of one `run_async` job: the value passed to `done`, or the error
--- the job raised. It is settled at most once.
--- @class test.Pending
--- @field settled boolean
--- @field ok boolean?  false when the job raised
--- @field value any  the value passed to `done`, or the job's error
--- @field listeners fun(ok: boolean, value: any)[]
local Pending = {}
Pending.__index = Pending

-- The child reports back by running a Lua string in the host. That string sees
-- only host globals, because a bundled module cannot be reached by `require`,
-- so open jobs live in one global table keyed by id.
_G.__test_nvim_pending = _G.__test_nvim_pending or {}
local next_id = 0

--- Only the first result counts, because a second `done` must not change a
--- value the host may already have read.
--- @param ok boolean
--- @param value any
function Pending:settle(ok, value)
  if self.settled then return end
  self.settled, self.ok, self.value = true, ok, value
  for _, cb in ipairs(self.listeners) do
    cb(ok, value)
  end
  self.listeners = {}
end

--- Block until the job settles, and return its value. Raises when the job
--- raised, or when it has not settled after `timeout_ms` (default 2000).
--- @param timeout_ms? integer
--- @return any
function Pending:wait(timeout_ms)
  timeout_ms = timeout_ms or 2000
  if not vim.wait(timeout_ms, function() return self.settled end, 1) then
    error(('run_async: no result after %d ms'):format(timeout_ms), 2)
  end
  if not self.ok then error('run_async: the child raised: ' .. tostring(self.value), 2) end
  return self.value
end

--- Call `cb(ok, value)` once the job settles, without blocking. `ok` is false
--- when the job raised, and `value` is then its error. The host handles the
--- child's result only while its own event loop runs, i.e., inside some
--- `vim.wait`. An error raised by `cb` surfaces in that RPC handler, not in the
--- spec, so `cb` should record what it saw and leave assertions to the spec.
--- @param cb fun(ok: boolean, value: any)
function Pending:on_settled(cb)
  -- A job that already settled still calls back on a later tick, so `cb`
  -- never runs before the line after `on_settled`, whichever finished first.
  if self.settled then
    vim.schedule(function()
      cb(self.ok --[[@as boolean]], self.value)
    end)
    return
  end
  table.insert(self.listeners, cb)
end

--- Start a function inside the child without blocking the host, and return
--- its pending result. The function receives a `done` callback; the value
--- passed to `done` settles the result, and so does an error raised before it.
--- The function is `string.dump`'d, so it cannot capture upvalues - use child
--- globals for state it must read.
--- @param f fun(done: fun(value?: any))
--- @return test.Pending
function Nvim:run_async(f)
  next_id = next_id + 1
  local id = next_id
  local pending = setmetatable({ settled = false, listeners = {} }, Pending)
  _G.__test_nvim_pending[id] = pending

  self:notify(
    'nvim_exec_lua',
    [[
      local code, id = ...
      -- A notification, not a request, so the child never blocks on a host
      -- that is itself blocked.
      local function settle(ok, value)
        vim.rpcnotify(1, 'nvim_exec_lua', [=[
          local id, ok, value = ...
          local pending = _G.__test_nvim_pending[id]
          _G.__test_nvim_pending[id] = nil
          if pending then pending:settle(ok, value) end
        ]=], { id, ok, value })
      end
      -- An error raised before `done` becomes the job's result, so the host
      -- sees it instead of a silent timeout.
      local ok, err = pcall(function()
        assert(loadstring(code))(function(value) settle(true, value) end)
      end)
      if not ok then settle(false, err) end
    ]],
    { string.dump(f), id }
  )

  return pending
end

--------------------------------------------------------------------------------
-- Input, screen, and waiting
--------------------------------------------------------------------------------

--- Type keys into the child nvim, auto-translating key-notation.
--- Simpler than feedkeys: no mode, no escape_ks - just virtual typing.
--- @param keys string  key notation (e.g. "ihello\<Esc>")
function Nvim:input(keys)
  local translated = self:request('nvim_replace_termcodes', keys, true, true, true)
  return self:request('nvim_input', translated)
end

--- Read the rendered grid, one string per row, status and command lines
--- included.
--- @return string[]
function Nvim:screen()
  return self:run(function()
    vim.cmd 'redraw!'
    local lines = {}
    for r = 1, vim.o.lines do
      local row = {}
      for c = 1, vim.o.columns do
        row[c] = vim.fn.screenstring(r, c)
      end
      lines[r] = table.concat(row)
    end
    return lines
  end) --[[@as string[] ]]
end

--- Wait until the work already queued with `vim.schedule` in the child has
--- run. Scheduled callbacks run in order, so a `done` scheduled now fires only
--- after that work. Raises after `timeout_ms` (default 2000).
--- @param timeout_ms? integer
function Nvim:drain(timeout_ms)
  self:run_async(function(done) vim.schedule(done) end):wait(timeout_ms)
end

--- Poll a child-side predicate until it returns true, and raise with `msg`
--- once `timeout_ms` (default 2000) passes.
---
--- Each attempt is its own RPC round trip, because the round trip - not an
--- in-child wait - is what lets the child's event loop dispatch pending work:
--- on some versions a single request's in-child wait never reaches that
--- checkpoint. `pred` is `string.dump`'d, so it cannot capture upvalues.
--- @param pred fun(): boolean
--- @param timeout_ms? integer
--- @param msg? string
function Nvim:wait_until(pred, timeout_ms, msg)
  timeout_ms = timeout_ms or 2000
  local deadline = vim.uv.now() + timeout_ms
  repeat
    if self:run(pred) then return end
    vim.wait(10)
  until vim.uv.now() >= deadline
  error(msg or ('wait_until: the predicate did not hold within %d ms'):format(timeout_ms), 2)
end

--- Stop the child, and wait for it to exit. Safe to call more than once.
function Nvim:stop()
  -- A child that already exited, e.g. on a second stop, has nothing to close.
  if vim.fn.jobwait({ self.chan }, 0)[1] ~= -1 then return end

  -- A callback can raise after the last `run`, which would have reported it,
  -- so read v:errmsg first. A child stuck in a busy loop never answers, and
  -- gets the same 2000 ms that `wait_until` allows by default.
  local reply = self:run_async(function(done) done(vim.v.errmsg) end)
  local answered = vim.wait(2000, function() return reply.settled end, 1)

  -- Closing the channel makes the child exit normally, which fires its
  -- `VimLeavePre`, where a coverage run writes the child's hits; waiting
  -- for the exit makes those hits complete before the run reads them. A busy
  -- child never reads the close either, so it is killed without its hits.
  vim.fn.chanclose(self.chan)
  if not answered or vim.fn.jobwait({ self.chan }, 2000)[1] == -1 then
    -- Not `jobstop`: its SIGTERM is handled only by the child's event loop,
    -- which a busy child never runs, and its fallback SIGKILL comes from a
    -- timer in this process, so it never fires when this process exits first,
    -- e.g. an isolated worker after its last case. The child would outlive
    -- the run, spinning.
    vim.uv.kill(vim.fn.jobpid(self.chan), 'sigkill')
    vim.fn.jobwait({ self.chan }, 1000)
  end

  -- Raise only once the child is gone, so a failing stop does not leak it.
  local errmsg = answered and reply.ok and reply.value or ''
  if errmsg ~= '' then error('the child reported an error: ' .. errmsg, 2) end
end

return Nvim
