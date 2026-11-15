-- These specs check `test.assert` with Lua's built-in `assert` and the helpers
-- below, not with `test.assert` itself, so a bug in the library cannot hide
-- itself.
local Test = require 'test'
local describe, it = Test.describe, Test.it
local T = Test.assert

--- @param want any
--- @param got any
local function same(want, got)
  assert(vim.deep_equal(want, got), ('want %s, got %s'):format(vim.inspect(want), vim.inspect(got)))
end

--- Run `f`, require it to raise, and return the error text.
--- @param f fun()
--- @return string
local function failure(f)
  local ok, err = pcall(f)
  assert(not ok, 'expected the assertion to fail')
  return tostring(err)
end

--- @param haystack string
--- @param needle string
local function has(haystack, needle)
  assert(haystack:find(needle, 1, true), ('missing %q in:\n%s'):format(needle, haystack))
end

describe('test.assert', function()
  it('names the spec line that called the failing assertion', function()
    has(failure(function() T.equal(1, 2) end), 'assert_spec.lua')
    has(failure(function() T(false) end), 'assert_spec.lua')
  end)

  it('puts the message on the first line', function()
    local err = failure(function() T.equal(1, 2, 'counts') end)
    has(err, 'equal failed: counts\n')
  end)

  it('prints a diff of the two values for every failure', function()
    local t = {}
    local failures = {
      ok = function() T.ok(nil) end,
      is_nil = function() T.is_nil(0) end,
      call = function() T(false) end,
      equal = function() T.equal(1, 2) end,
      not_equal = function() T.not_equal(t, t) end,
      deep_equal = function() T.deep_equal({ 1 }, { 2 }) end,
      not_deep_equal = function() T.not_deep_equal({ 1 }, { 1 }) end,
      contains = function() T.contains({ 'x' }, 'y') end,
      matches = function() T.matches('x', '^%d') end,
      raises_returned = function()
        T.raises(function() end)
      end,
      raises_text = function()
        T.raises(function() error 'bad' end, 'good')
      end,
    }
    for name, f in pairs(failures) do
      local err = failure(f)
      assert(err:find('\n--- got\n+++ want\n', 1, true), name .. ':\n' .. err)
    end
  end)

  describe('ok and the namespace call', function()
    it('return the value when it is truthy', function()
      same(3, T.ok(3))
      same('x', T 'x')
    end)

    it('fail on false and nil', function()
      has(failure(function() T.ok(nil, 'set') end), 'ok failed: set\nexpected a truthy value\n')
      has(failure(function() T(false) end), '- false\n+ true')
    end)
  end)

  describe('is_nil', function()
    it('accepts nil and vim.NIL', function()
      T.is_nil(nil)
      T.is_nil(vim.NIL)
    end)

    it('fails on any other value, false included', function()
      has(
        failure(function() T.is_nil(false) end),
        'expected nil or vim.NIL\n--- got\n+++ want\n- false\n+ nil'
      )
    end)
  end)

  describe('equal and not_equal', function()
    it('compare tables by identity', function()
      local t = {}
      T.equal(t, t)
      T.not_equal({}, {})
      has(failure(function() T.equal({}, {}) end), 'equal failed')
      has(failure(function() T.not_equal(t, t) end), 'not_equal failed')
    end)

    it('diff both values and name differing types', function()
      local err = failure(function() T.equal(1, '1') end)
      has(err, 'expected the same value (got a number, want a string)\n')
      has(err, '- 1\n+ "1"')
    end)

    it('point out deep-equal tables that are not the same table', function()
      has(failure(function() T.equal({ 1 }, { 1 }) end), 'two deep-equal tables (use deep_equal)')
    end)

    it('show the shared value as unchanged lines', function()
      local t = { 'a' }
      has(failure(function() T.not_equal(t, t) end), '+++ want\n  "a"')
    end)
  end)

  describe('deep_equal and not_deep_equal', function()
    it('compare contents', function()
      T.deep_equal({ a = { 1, 2 } }, { a = { 1, 2 } })
      T.not_deep_equal({ 1 }, { 2 })
      has(failure(function() T.not_deep_equal({ 1 }, { 1 }) end), 'not_deep_equal failed')
    end)

    it('diff a list of strings one element per line', function()
      local err = failure(
        function() T.deep_equal({ 'a', 'b ', 'c' }, { 'a', 'b', 'c' }, 'lines') end
      )
      has(
        err,
        'deep_equal failed: lines\nexpected equal contents\n--- got\n+++ want\n  "a"\n- "b "\n+ "b"\n  "c"'
      )
    end)

    it('diff a string one line per line', function()
      local err = failure(function() T.deep_equal('a\nb', 'a\nc') end)
      has(err, '  "a"\n- "b"\n+ "c"')
    end)

    it('diff other values through vim.inspect', function()
      local err = failure(function() T.deep_equal({ 1 }, { 2 }) end)
      has(err, '- { 1 }\n+ { 2 }')
    end)

    it('diff a pure insertion', function()
      local err = failure(function() T.deep_equal({ 'a', 'b' }, { 'a', 'x', 'b' }) end)
      has(err, '--- got\n+++ want\n  "a"\n+ "x"\n  "b"')
    end)

    it('diff a pure deletion', function()
      local err = failure(function() T.deep_equal({ 'a', 'x', 'b' }, { 'a', 'b' }) end)
      has(err, '--- got\n+++ want\n  "a"\n- "x"\n  "b"')
    end)

    it('diff a replacement as a deletion followed by an addition', function()
      local err = failure(function() T.deep_equal({ 'old' }, { 'new' }) end)
      has(err, '--- got\n+++ want\n- "old"\n+ "new"')
    end)

    it('diff with the longest run of shared lines kept', function()
      local err = failure(
        function() T.deep_equal({ 'c', 'c', 'b' }, { 'b', 'b', 'b', 'c', 'c', 'a', 'a' }) end
      )
      has(err, '+ "b"\n+ "b"\n+ "b"\n  "c"\n  "c"\n- "b"\n+ "a"\n+ "a"')
    end)

    it('name the types when they differ', function()
      local err = failure(function() T.deep_equal('a', { 'a' }) end)
      has(err, '(got a string, want a table)')
    end)
  end)

  describe('contains', function()
    it('finds a plain substring', function()
      T.contains('a - b + c', '- b +')
      has(failure(function() T.contains('abc', 'a.c') end), 'contains failed')
    end)

    it('finds a deep-equal list element', function()
      T.contains({ { kind = 'save' }, { kind = 'quit' } }, { kind = 'quit' })
      local err = failure(function() T.contains({ 'x', 'y' }, 'z') end)
      has(err, 'to contain the needle (want)\n--- got\n+++ want\n- "x"\n- "y"\n+ "z"')
    end)

    it('rejects a haystack it cannot search', function()
      --- @diagnostic disable-next-line: param-type-mismatch
      has(failure(function() T.contains(1, 'a') end), 'haystack must be a string or a list')
      has(failure(function() T.contains('a', 1) end), 'needs a string needle')
    end)
  end)

  describe('matches', function()
    it('matches a Lua pattern', function()
      T.matches('12 lines', '^%d+ lines$')
      has(failure(function() T.matches('x lines', '^%d+') end), '- "x lines"\n+ "^%d+"')
    end)
  end)

  describe('raises', function()
    it('returns the error', function()
      local err = T.raises(function() error { code = 7 } end)
      same({ code = 7 }, err)
    end)

    it('checks the error for a plain substring', function()
      T.raises(function() error 'bad - input' end, 'bad - input')
      local err = failure(function()
        T.raises(function() error 'bad' end, 'good')
      end)
      has(err, 'raises failed\nexpected the error (got) to contain the text (want)\n')
      has(err, 'bad"\n+ "good"')
    end)

    it('fails when the function returns', function()
      has(
        failure(function()
          T.raises(function() end)
        end),
        'it returned (got)\n--- got\n+++ want\n- {}\n+ "an error"'
      )
      has(
        failure(function()
          T.raises(function() return 1, 2 end, 'boom')
        end),
        '- { 1, 2 }\n+ "boom"'
      )
    end)
  end)
end)
