---@diagnostic disable: global-in-non-module

local Assert = require 'test.assert'

--- Nvim remote-control helper.
--- Spawns a child `nvim --headless --embed` with RPC on stdio,
--- drives it via msgpack-RPC, and snapshots the screen grid.
---
--- This child is headless but is NOT subject to the host (busted runner) nvim's
--- limitations: it has a real event loop driven by RPC, so `TextChanged`/
--- `TextChangedI` autocmds fire naturally from real input, and programmatic
--- `:startinsert` genuinely enters insert mode. The mode change (and any
--- scheduled work) is only observable across an RPC round-trip (a later `run`/
--- `request`), NOT within the same `run` that issued it — the round-trip is the
--- event-loop flush point. See AGENTS.md's "Test environment" section for the
--- full host/child distinction.

--- @class test.Screen
--- @field lines string[]      composited screen grid, one string per row (full TUI screenshot)
--- @field rows integer        grid height (vim.o.lines)
--- @field columns integer     grid width (vim.o.columns)

--- @class test.Nvim
--- @field jobid integer
--- @field chan integer
local Nvim = {}
Nvim.__index = Nvim

--- @param opts? { columns?: integer, rows?: integer, rtp?: string }
--- @return test.Nvim  handle with :stop(), :request(method, ...), :notify(...), :screen()
function Nvim.start(opts)
  opts = opts or {}
  --- @cast opts { columns?: integer, rows?: integer, rtp?: string }
  --- @type test.Nvim
  local self = setmetatable({}, Nvim)

  --- @type string[]
  local argv = { vim.v.argv[1], '--headless', '--embed', '-n', '-u', 'NORC' }
  if opts.columns then
    vim.list_extend(argv, { '--cmd', ('set columns=%d'):format(opts.columns) })
  end
  if opts.rows then vim.list_extend(argv, { '--cmd', ('set lines=%d'):format(opts.rows) }) end

  local jobid = vim.fn.jobstart(argv, {
    rpc = true,
    -- Plugins read NVIM_TEST to disable debounce and timers in the child.
    -- Unset it inside the child when a spec needs the production timing path.
    env = { NVIM_TEST = 'true' },
  })
  if jobid <= 0 then error('jobstart failed: ' .. jobid, 2) end
  self.jobid = jobid
  -- With rpc=true the job-id IS the channel-id.
  self.chan = jobid

  -- Wait for readiness: retry nvim_get_api_info up to ~1s.
  if
    not vim.wait(
      1000,
      function() return pcall(vim.rpcrequest, self.chan, 'nvim_get_api_info') end,
      10
    )
  then
    vim.fn.jobstop(jobid)
    error('child nvim never became ready', 2)
  end

  -- Add repo to child rtp.
  local rtp = opts.rtp or vim.fn.getcwd()
  self:request('nvim_command', 'set rtp+=' .. vim.fn.escape(rtp, ' '))

  return self
end

--- @param method string
--- @param ... any
function Nvim:request(method, ...) return vim.rpcrequest(self.chan, method, ...) end

--- @param method string
--- @param ... any
function Nvim:notify(method, ...) vim.rpcnotify(self.chan, method, ...) end

--- Run a function inside the child and return its result.
--- The function is serialized via `string.dump` — upvalues are NOT preserved,
--- so pass the data it needs as arguments.
--- @param f fun(...): any
--- @param ... any  arguments forwarded to `f`
--- @return any
function Nvim:run(f, ...)
  return self:request(
    'nvim_exec_lua',
    'local f = ...; return assert(loadstring(f))(select(2, ...))',
    { string.dump(f), ... }
  )
end

--- Run a function inside the child without blocking the host.
--- The function receives a `done` callback; calling `done(results)` runs
--- `on_done(results)` in the host. The function is `string.dump`'d, so it
--- cannot capture upvalues — use child globals for state it must read.
--- @param f fun(done: fun(results: any))
--- @param on_done fun(results: any)
function Nvim:run_async(f, on_done)
  assert(
    type(on_done) == 'function',
    ('run_async: on_done must be a function, got %s'):format(type(on_done))
  )

  _G.__test_nvim_async_cb_registry = _G.__test_nvim_async_cb_registry or {}
  _G.__test_nvim_async_cb_counter = (_G.__test_nvim_async_cb_counter or 0) + 1
  local cb_id = _G.__test_nvim_async_cb_counter
  _G.__test_nvim_async_cb_registry[cb_id] = function(results)
    _G.__test_nvim_async_cb_registry[cb_id] = nil
    on_done(results)
  end

  self:notify(
    'nvim_exec_lua',
    [[
      local code, cb_id = ...
      local fn = assert(loadstring(code))
      fn(function(results)
        vim.rpcrequest(
          1,
          'nvim_exec_lua',
          '_G.__test_nvim_async_cb_registry[' .. tostring(cb_id) .. '](...)',
          { results }
        )
      end)
    ]],
    { string.dump(f), cb_id }
  )
end

--- Type keys into the child nvim, auto-translating key-notation.
--- Simpler than feedkeys: no mode, no escape_ks — just virtual typing.
--- @param keys string  key notation (e.g. "ihello\<Esc>")
function Nvim:input(keys)
  local translated = self:request('nvim_replace_termcodes', keys, true, true, true)
  return self:request('nvim_input', translated)
end

--- @return test.Screen
function Nvim:screen()
  return self:run(function()
    vim.cmd 'redraw!'
    local lines = {}
    for r = 1, vim.o.lines do
      local row = {}
      for c = 1, vim.o.columns do
        row[c] = vim.fn.screenstring(r, c) or ' '
      end
      lines[r] = table.concat(row)
    end
    return {
      lines = lines,
      rows = vim.o.lines,
      columns = vim.o.columns,
    }
  end) --[[@as test.Screen]]
end

--- Flush scheduled work in the child.
---
--- The work being flushed is `vim.schedule`'d, and scheduled callbacks run in
--- FIFO order, so queueing a sentinel after it and waiting on the sentinel
--- releases as soon as the queue drains instead of after a fixed sleep. `ms` is
--- only a safety cap, passed as an argument because the closure cannot capture
--- upvalues.
--- @param ms? integer  safety cap (default 1000)
function Nvim:drain(ms)
  self:run(function(...)
    local cap = ... --- @type integer?
    local done = false
    vim.schedule(function() done = true end)
    vim.wait(cap or 1000, function() return done end, 1)
  end, ms)
end

--- Poll a child-side predicate until it returns true.
---
--- Each attempt is its own RPC round trip, because the round trip — not an
--- in-child wait — is what lets the child's event loop dispatch pending work:
--- on some versions a single request's in-child wait never reaches that
--- checkpoint. `pred` is `string.dump`'d, so it cannot capture upvalues.
--- @param pred fun(): boolean
--- @param timeout_ms? integer  give up after this many milliseconds (default 2000)
--- @return boolean  true once `pred` returned true
function Nvim:wait_until(pred, timeout_ms)
  local deadline = vim.uv.now() + (timeout_ms or 2000)
  repeat
    if self:run(pred) then return true end
    vim.wait(10)
  until vim.uv.now() >= deadline
  return false
end

--- Capture the child's screen and assert it matches `expected` line for line.
--- On mismatch, raises with a line diff.
--- @param expected string[]  expected screen lines
--- @param msg? string  assertion label
function Nvim:assert_screenshot(expected, msg)
  local got = self:screen().lines
  if vim.deep_equal(got, expected) then return end
  local got_lines = vim.tbl_map(vim.inspect, got) --- @type string[]
  local want_lines = vim.tbl_map(vim.inspect, expected) --- @type string[]
  error((msg or 'screenshot mismatch') .. '\n' .. Assert.diff(got_lines, want_lines), 2)
end

--- Stop the child. Safe to call more than once.
function Nvim:stop() vim.fn.jobstop(self.jobid) end

return Nvim
