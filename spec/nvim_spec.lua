--- @diagnostic disable: undefined-field
--- @diagnostic disable: global-in-non-module

local Nvim = require('test').Nvim

describe('test.Nvim', function()
  local nv --- @type test.Nvim

  before_each(function() nv = Nvim.start { columns = 40, rows = 12 } end)

  after_each(function() nv:stop() end)

  it('runs a function in the child', function()
    assert.are.same(42, nv:run(function() return 40 + 2 end))
  end)

  it('returns a nil result as vim.NIL, which is_nil accepts', function()
    local result = nv:run(function() return nil end)
    assert.are.same(vim.NIL, result)
    require('test').assert.is_nil(result)
  end)

  it('passes arguments to the child function', function()
    local result = nv:run(function(...)
      local a, b = ...
      return a .. b
    end, 'x', 'y')
    assert.are.same('xy', result)
  end)

  it('adds env to the child environment', function()
    local child = Nvim.start { env = { TEST_NVIM_SPEC = 'set' } }
    local value = child:run(function() return vim.env.TEST_NVIM_SPEC end)
    child:stop()
    assert.are.same('set', value)
  end)

  describe('run_async', function()
    it('returns a pending result that wait blocks on', function()
      local pending = nv:run_async(function(done)
        vim.schedule(function() done 'finished' end)
      end)
      assert.are.same('finished', pending:wait())
    end)

    it('runs several jobs concurrently', function()
      local a = nv:run_async(function(done)
        vim.defer_fn(function() done 'a' end, 50)
      end)
      local b = nv:run_async(function(done)
        vim.defer_fn(function() done 'b' end, 50)
      end)
      local started = vim.uv.now()
      assert.are.same({ 'a', 'b' }, { a:wait(), b:wait() })
      assert.is_true(vim.uv.now() - started < 95, 'the jobs ran one after another')
    end)

    it('reports a job error from wait', function()
      local pending = nv:run_async(function() error 'job broke' end)
      local ok, err = pcall(pending.wait, pending)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find('job broke', 1, true))
    end)

    it('raises when the job never settles', function()
      local pending = nv:run_async(function() end)
      local ok, err = pcall(pending.wait, pending, 50)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find('no result after 50 ms', 1, true))
    end)

    it('keeps the first result when done is called twice', function()
      local pending = nv:run_async(function(done)
        done 'first'
        done 'second'
      end)
      assert.are.same('first', pending:wait())
      nv:drain()
      vim.wait(20)
      assert.are.same('first', pending:wait())
    end)

    it('calls on_settled without blocking', function()
      local seen
      nv:run_async(function(done)
        vim.schedule(function() done 'later' end)
      end):on_settled(function(ok, value) seen = { ok, value } end)
      assert.is_nil(seen)
      assert.is_true(vim.wait(1000, function() return seen ~= nil end))
      assert.are.same({ true, 'later' }, seen)
    end)

    it('passes a job error to on_settled', function()
      local seen
      nv:run_async(function() error 'job broke' end)
        :on_settled(function(ok, value) seen = { ok, tostring(value) } end)
      assert.is_true(vim.wait(1000, function() return seen ~= nil end))
      --- @cast seen [boolean, string]
      assert.is_false(seen[1])
      assert.is_truthy(seen[2]:find('job broke', 1, true))
    end)

    it('calls on_settled on a later tick for a settled job', function()
      local pending = nv:run_async(function(done) done 'now' end)
      pending:wait()
      local seen
      pending:on_settled(function(_, value) seen = value end)
      assert.is_nil(seen)
      assert.is_true(vim.wait(1000, function() return seen ~= nil end))
      assert.are.same('now', seen)
    end)
  end)

  it('types keys into the child', function()
    nv:input 'ihello<Esc>'
    local lines = nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end)
    assert.are.same({ 'hello' }, lines)
  end)

  it('captures the screen as one string per row', function()
    local screen = nv:screen()
    assert.are.same(12, #screen)
    assert.are.same(40, #screen[1])
  end)

  it('drains scheduled child work', function()
    nv:run(function()
      _G.drained = false
      vim.schedule(function() _G.drained = true end)
    end)
    nv:drain()
    assert.is_true(nv:run(function() return _G.drained end))
  end)

  it('waits for a child predicate across round trips', function()
    nv:run(function()
      _G.ticks = 0
      vim.schedule(function() _G.ticks = 1 end)
    end)
    nv:wait_until(function() return _G.ticks == 1 end)
  end)

  it('raises when a predicate never holds', function()
    local ok, err = pcall(nv.wait_until, nv, function() return false end, 50, 'never ready')
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find('never ready', 1, true))
  end)

  it('can notify and request', function()
    nv:notify('nvim_command', 'let g:test_value = 7')
    assert.are.same(7, nv:request('nvim_get_var', 'test_value'))
  end)
end)
