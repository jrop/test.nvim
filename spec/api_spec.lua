--- @diagnostic disable: undefined-field

local Assert = require 'test.assert'
local Nvim = require 'test.nvim'
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
  it('exports the facade surface', function()
    assert.are.same({ 'Nvim', 'assert', 'with_buf' }, api_names(Test))
    assert.are.same(Nvim, Test.Nvim)
    assert.are.same(Assert, Test.assert)
    assert.are.same('function', type(Test.with_buf))
  end)

  it('exports the assert surface', function()
    assert.are.same({ 'deep_equal', 'diff' }, api_names(Assert))
    assert.are.same('function', type(Assert.diff))
    assert.are.same('function', type(Assert.deep_equal))
  end)

  it('exports the Nvim class surface', function()
    local public = api_names(Nvim)
    assert.are.same({
      'assert_screenshot',
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
