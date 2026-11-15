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
