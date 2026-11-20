--- @diagnostic disable: global-in-non-module

local Test = require 'test'
local describe, it, before_each, after_each =
  Test.describe, Test.it, Test.before_each, Test.after_each
local Nvim, assert = Test.Nvim, Test.assert

describe('test.Nvim', function()
  local nv --- @type test.Nvim

  before_each(function() nv = Nvim.start { columns = 40, rows = 12 } end)

  after_each(function() nv:stop() end)

  it('runs a function in the child', function()
    assert.deep_equal(nv:run(function() return 40 + 2 end), 42)
  end)

  it('returns a nil result as vim.NIL, which is_nil accepts', function()
    local result = nv:run(function() return nil end)
    assert.deep_equal(result, vim.NIL)
    assert.is_nil(result)
  end)

  it('passes arguments to the child function', function()
    local result = nv:run(function(...)
      local a, b = ...
      return a .. b
    end, 'x', 'y')
    assert.deep_equal(result, 'xy')
  end)

  it('returns from a function whose output runs past the screen', function()
    -- Output longer than the 12-row screen would stop at a "-- More --" prompt
    -- that nothing answers.
    local result = nv:run(function()
      vim.api.nvim_echo({ { table.concat(vim.fn.range(1, 50), '\n') } }, true, {})
      return 'done'
    end)
    assert.equal(result, 'done')
  end)

  it('raises when the function triggered a callback in the child that raised', function()
    assert.raises(function()
      nv:run(function()
        vim.api.nvim_create_autocmd('User', {
          pattern = 'Boom',
          callback = function() error 'child callback broke' end,
        })
        vim.api.nvim_exec_autocmds('User', { pattern = 'Boom' })
      end)
    end, 'child callback broke')
  end)

  it('raises on the next run for a callback that raised in the child since the last one', function()
    nv:run(function()
      vim.schedule(function() error 'scheduled in the child' end)
    end)
    nv:drain()
    assert.raises(function()
      nv:run(function() end)
    end, 'scheduled in the child')
  end)

  it('raises on stop for a callback that raised in the child after the last run', function()
    local child = Nvim.start()
    child:run(function()
      vim.schedule(function() error 'raised before stop' end)
    end)
    child:drain()
    assert.raises(function() child:stop() end, 'raised before stop')
  end)

  it('stops a child stuck in a busy loop', function()
    local child = Nvim.start()
    child:run(function() end)
    -- A notification, so the host does not wait for the loop that never ends.
    child:notify('nvim_exec_lua', 'while true do end', {})
    local pid = vim.fn.jobpid(child.chan)
    local started = vim.uv.hrtime()
    child:stop()
    assert.equal((vim.uv.hrtime() - started) / 1e6 < 4000, true, 'stop returned')
    -- Signal 0 checks that the process exists without signalling it.
    assert.ok(vim.uv.kill(pid, 0) == nil, 'the child outlived stop')
  end)

  it('adds env to the child environment', function()
    local child = Nvim.start { env = { TEST_NVIM_SPEC = 'set' } }
    local value = child:run(function() return vim.env.TEST_NVIM_SPEC end)
    child:stop()
    assert.deep_equal(value, 'set')
  end)

  describe('run_async', function()
    it('returns a pending result that wait blocks on', function()
      local pending = nv:run_async(function(done)
        vim.schedule(function() done 'finished' end)
      end)
      assert.deep_equal(pending:wait(), 'finished')
    end)

    it('runs several jobs concurrently', function()
      local a = nv:run_async(function(done)
        vim.defer_fn(function() done 'a' end, 50)
      end)
      local b = nv:run_async(function(done)
        vim.defer_fn(function() done 'b' end, 50)
      end)
      local started = vim.uv.now()
      assert.deep_equal({ a:wait(), b:wait() }, { 'a', 'b' })
      assert.equal(vim.uv.now() - started < 95, true, 'the jobs ran one after another')
    end)

    it('reports a job error from wait', function()
      local pending = nv:run_async(function() error 'job broke' end)
      assert.raises(function() pending:wait() end, 'job broke')
    end)

    it('raises when the job never settles', function()
      local pending = nv:run_async(function() end)
      assert.raises(function() pending:wait(50) end, 'no result after 50 ms')
    end)

    it('keeps the first result when done is called twice', function()
      local pending = nv:run_async(function(done)
        done 'first'
        done 'second'
      end)
      assert.deep_equal(pending:wait(), 'first')
      nv:drain()
      vim.wait(20)
      assert.deep_equal(pending:wait(), 'first')
    end)

    it('calls on_settled without blocking', function()
      local seen
      nv:run_async(function(done)
        vim.schedule(function() done 'later' end)
      end):on_settled(function(ok, value) seen = { ok, value } end)
      assert.is_nil(seen)
      assert.equal(vim.wait(1000, function() return seen ~= nil end), true)
      assert.deep_equal(seen, { true, 'later' })
    end)

    it('passes a job error to on_settled', function()
      local seen
      nv:run_async(function() error 'job broke' end)
        :on_settled(function(ok, value) seen = { ok, tostring(value) } end)
      assert.equal(vim.wait(1000, function() return seen ~= nil end), true)
      --- @cast seen [boolean, string]
      assert.equal(seen[1], false)
      assert.contains(seen[2], 'job broke')
    end)

    it('calls on_settled on a later tick for a settled job', function()
      local pending = nv:run_async(function(done) done 'now' end)
      pending:wait()
      local seen
      pending:on_settled(function(_, value) seen = value end)
      assert.is_nil(seen)
      assert.equal(vim.wait(1000, function() return seen ~= nil end), true)
      assert.deep_equal(seen, 'now')
    end)
  end)

  it('types keys into the child', function()
    nv:input 'ihello<Esc>'
    local lines = nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end)
    assert.deep_equal(lines, { 'hello' })
  end)

  it('captures the screen as one string per row', function()
    local screen = nv:screen()
    assert.deep_equal(#screen, 12)
    assert.deep_equal(#screen[1], 40)
  end)

  it('drains scheduled child work', function()
    nv:run(function()
      _G.drained = false
      vim.schedule(function() _G.drained = true end)
    end)
    nv:drain()
    assert.equal(nv:run(function() return _G.drained end), true)
  end)

  it('waits for a child predicate across round trips', function()
    nv:run(function()
      _G.ticks = 0
      vim.schedule(function() _G.ticks = 1 end)
    end)
    nv:wait_until(function() return _G.ticks == 1 end)
  end)

  it('raises when a predicate never holds', function()
    assert.raises(function()
      nv:wait_until(function() return false end, 50, 'never ready')
    end, 'never ready')
  end)

  it('can notify and request', function()
    nv:notify('nvim_command', 'let g:test_value = 7')
    assert.deep_equal(nv:request('nvim_get_var', 'test_value'), 7)
  end)
end)

describe('Nvim.script', function()
  it("runs a script under the suite's own Neovim and returns its output and exit code", function()
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ "io.stdout:write(arg[1], ' ', vim.v.progpath)", 'os.exit(3)' }, script)
    local proc = Nvim.script(script, { 'given' })
    vim.fn.delete(script)
    assert.equal(proc.code, 3, proc.stderr)
    assert.equal(proc.stdout, 'given ' .. vim.v.progpath)
  end)
end)
