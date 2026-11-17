local Test = require 'test'
local describe, it = Test.describe, Test.it
local assert = Test.assert

--- Sorted public names. `__index` is the class table's metatable hook, not a
--- name the harness exposes.
--- @param t table<string, any>
--- @return string[]
local function api_names(t)
  local out = {} --- @type string[]
  for k in pairs(t) do
    if k ~= '__index' then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

describe('public API', function()
  -- A bundle returns only the `test` module, so these lists are everything a
  -- vendored consumer can reach.
  it(
    'exports the harness, the assertions, and the spec API from one module',
    function()
      assert.deep_equal(api_names(Test), {
        'Nvim',
        'after_all',
        'after_each',
        'assert',
        'before_all',
        'before_each',
        'describe',
        'it',
        'pending',
      })
    end
  )

  it('exports the assertions, and the namespace is callable', function()
    local names = api_names(assert)
    assert.deep_equal(names, {
      'contains',
      'deep_equal',
      'equal',
      'is_nil',
      'matches',
      'not_deep_equal',
      'not_equal',
      'ok',
      'raises',
    })
    for _, name in ipairs(names) do
      assert.deep_equal(type(assert[name]), 'function', name)
    end
    assert.deep_equal(type(getmetatable(assert).__call), 'function')
  end)

  it('exports the Nvim class surface', function()
    local Nvim = Test.Nvim
    local public = api_names(Nvim)
    assert.deep_equal(public, {
      'drain',
      'input',
      'notify',
      'request',
      'run',
      'run_async',
      'screen',
      'script',
      'start',
      'stop',
      'wait_until',
    })
    assert.deep_equal(Nvim.__index, Nvim)
    for _, name in ipairs(public) do
      assert.deep_equal(type(Nvim[name]), 'function', name)
    end
  end)
end)
