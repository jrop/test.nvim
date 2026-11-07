--- @diagnostic disable: undefined-field

local Assert = require 'test.assert'

describe('test.assert', function()
  it('diffs a pure insertion', function()
    local diff = Assert.diff({ 'a', 'b' }, { 'a', 'x', 'b' })
    assert.are.same('--- got\n+++ want\n  a\n+ x\n  b', diff)
  end)

  it('diffs a pure deletion', function()
    local diff = Assert.diff({ 'a', 'x', 'b' }, { 'a', 'b' })
    assert.are.same('--- got\n+++ want\n  a\n- x\n  b', diff)
  end)

  it('renders a replacement as a deletion followed by an addition', function()
    local diff = Assert.diff({ 'old' }, { 'new' })
    assert.are.same('--- got\n+++ want\n- old\n+ new', diff)
  end)

  it(
    'returns for deep-equal values',
    function() Assert.deep_equal({ a = { 1, 2 } }, { a = { 1, 2 } }) end
  )

  it('reports a readable diff on mismatch', function()
    local ok, err = pcall(Assert.deep_equal, { 1 }, { 2 }, 'numbers')
    assert.is_false(ok)
    --- @cast err string
    assert.is_truthy(err:find('deep_equal failed: numbers', 1, true))
    assert.is_truthy(err:find('- { 1 }', 1, true))
    assert.is_truthy(err:find('+ { 2 }', 1, true))
  end)
end)
