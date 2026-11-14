--- @diagnostic disable: undefined-field

local Test = require 'test'

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
    'exports Nvim and assert from the one entry module',
    function() assert.are.same({ 'Nvim', 'assert' }, api_names(Test)) end
  )

  it('exports the assertions, and the namespace is callable', function()
    local names = api_names(Test.assert)
    assert.are.same({
      'contains',
      'deep_equal',
      'equal',
      'is_nil',
      'matches',
      'not_deep_equal',
      'not_equal',
      'ok',
      'raises',
    }, names)
    for _, name in ipairs(names) do
      assert.are.same('function', type(Test.assert[name]), name)
    end
    assert.are.same('function', type(getmetatable(Test.assert).__call))
  end)

  it('exports the Nvim class surface', function()
    local Nvim = Test.Nvim
    local public = api_names(Nvim)
    assert.are.same({
      'drain',
      'input',
      'notify',
      'request',
      'run',
      'run_async',
      'screen',
      'start',
      'stop',
      'wait_until',
    }, public)
    assert.are.same(Nvim, Nvim.__index)
    for _, name in ipairs(public) do
      assert.are.same('function', type(Nvim[name]), name)
    end
  end)
end)
