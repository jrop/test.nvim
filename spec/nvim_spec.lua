--- @diagnostic disable: undefined-field
--- @diagnostic disable: global-in-non-module

local Nvim = require 'test.nvim'

describe('test.nvim', function()
  local nv --- @type test.Nvim

  before_each(function() nv = Nvim.start { columns = 40, rows = 12 } end)

  after_each(function() nv:stop() end)

  it('runs a function in the child', function()
    assert.are.same(42, nv:run(function() return 40 + 2 end))
  end)

  it('passes arguments to the child function', function()
    local result = nv:run(function(...)
      local a, b = ...
      return a .. b
    end, 'x', 'y')
    assert.are.same('xy', result)
  end)

  it('runs an async child function', function()
    local result
    nv:run_async(function(done)
      vim.schedule(function() done 'finished' end)
    end, function(value) result = value end)
    assert.is_true(vim.wait(1000, function() return result ~= nil end))
    assert.are.same('finished', result)
  end)

  it('types keys into the child', function()
    nv:input 'ihello<Esc>'
    local lines = nv:run(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end)
    assert.are.same({ 'hello' }, lines)
  end)

  it('captures the screen and matches a screenshot', function()
    local screen = nv:screen()
    assert.are.same(40, screen.columns)
    assert.are.same(12, screen.rows)
    assert.are.same(12, #screen.lines)
    nv:assert_screenshot(screen.lines)
  end)

  it('reports a screenshot mismatch with a diff', function()
    local expected = nv:screen().lines
    expected[1] = expected[1] .. ' wrong'
    local ok, err = pcall(nv.assert_screenshot, nv, expected)
    assert.is_false(ok)
    --- @cast err string
    assert.is_truthy(err:find('screenshot mismatch', 1, true))
    assert.is_truthy(err:find('\n- ', 1, true))
    assert.is_truthy(err:find('\n+ ', 1, true))
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
    assert.is_true(nv:wait_until(function() return _G.ticks == 1 end))
  end)

  it('gives up on a predicate that never holds', function()
    assert.is_false(nv:wait_until(function() return false end, 50))
  end)

  it('can notify and request', function()
    nv:notify('nvim_command', 'let g:test_value = 7')
    assert.are.same(7, nv:request('nvim_get_var', 'test_value'))
  end)
end)
