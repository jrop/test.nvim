--- Node-style assertions. Each one returns normally when its check holds, and
--- otherwise raises an error whose first line is `<name> failed` (plus `: msg`
--- when a message is given), followed by a line saying what was expected and a
--- diff of the two values involved. Errors are raised at the caller's level, so
--- a failure names the spec's line.
--- @class test.assert
--- @overload fun(value: any, msg?: string): any
local M = {}

--- An empty table is not a string list here, because it would print no lines
--- and leave a failure with an empty diff; `vim.inspect` prints it as `{}`.
--- @param value any
--- @return boolean
local function is_string_list(value)
  if type(value) ~= 'table' or #value == 0 or not vim.islist(value) then return false end
  for _, v in ipairs(value) do
    if type(v) ~= 'string' then return false end
  end
  return true
end

--- Turn a value into the lines a failure prints. A string and a list of
--- strings print one entry per line, because `vim.inspect` would put a whole
--- buffer on one line and make its diff useless. Each entry is quoted, so
--- trailing whitespace and a number standing in for a string stay visible.
--- @param value any
--- @return string[]
local function lines_of(value)
  if type(value) == 'string' then
    return vim.tbl_map(vim.inspect, vim.split(value, '\n', { plain = true }))
  end
  if is_string_list(value) then return vim.tbl_map(vim.inspect, value) end
  return vim.split(vim.inspect(value), '\n', { plain = true })
end

--- Build the shortest line diff turning `got` into `want`. Unchanged lines are
--- prefixed with two spaces, deletions with `- `, and insertions with `+ `; a
--- replaced line renders as `-` then `+`.
--- @param got string[]
--- @param want string[]
--- @return string
local function diff(got, want)
  local m, n = #got, #want
  -- `cost[i][j]` is the fewest deletions and insertions turning `got[i..]` into
  -- `want[j..]`. This is Levenshtein distance without its replace move,
  -- because a replaced line prints as a `-` line plus a `+` line and so costs
  -- two lines, not one. The table is built over suffixes, so the walk below
  -- runs forward from the first lines and emits the diff in order.
  -- Integer keys say every cell is written before it is read, which an array
  -- type would make each index re-narrow.
  local cost = {} --- @type table<integer, table<integer, integer>>
  for i = m + 1, 1, -1 do
    cost[i] = {}
    for j = n + 1, 1, -1 do
      if i > m then
        cost[i][j] = n + 1 - j
      elseif j > n then
        cost[i][j] = m + 1 - i
      elseif got[i] == want[j] then
        cost[i][j] = cost[i + 1][j + 1]
      else
        cost[i][j] = 1 + math.min(cost[i + 1][j], cost[i][j + 1])
      end
    end
  end

  local out = { '--- got', '+++ want' }
  local i, j = 1, 1
  while i <= m or j <= n do
    if i <= m and j <= n and got[i] == want[j] then
      out[#out + 1] = '  ' .. got[i]
      i, j = i + 1, j + 1
    elseif j > n or (i <= m and cost[i + 1][j] <= cost[i][j + 1]) then
      -- Deleting first on ties renders a replaced line as `-` then `+`.
      out[#out + 1] = '- ' .. got[i]
      i = i + 1
    else
      out[#out + 1] = '+ ' .. want[j]
      j = j + 1
    end
  end
  return table.concat(out, '\n')
end

--- Raise a failure from an assertion that a spec called directly, so level 3
--- skips both this function and the assertion. Every failure has the same
--- shape: the header, a note saying what was expected, and a diff of `got`
--- against `want`.
--- @param name string
--- @param msg string?
--- @param note string
--- @param got any
--- @param want any
--- @return never
local function fail(name, msg, note, got, want)
  local header = name .. ' failed' .. (msg and (': ' .. msg) or '')
  error(('%s\n%s\n%s'):format(header, note, diff(lines_of(got), lines_of(want))), 3)
end

--- A string and a list of the same lines print alike, and so do `1` and a
--- table holding `1` on one line, so a mismatch in type alone would show a
--- diff with no changed lines. The note names both types.
--- @param got any
--- @param want any
--- @param note string
--- @return string
local function with_types(got, want, note)
  if type(got) == type(want) then return note end
  return ('%s (got a %s, want a %s)'):format(note, type(got), type(want))
end

--- @param value any
--- @param msg? string
--- @return any value
function M.ok(value, msg)
  if not value then fail('ok', msg, 'expected a truthy value', value, true) end
  return value
end

--- Check that `value` is `nil` or `vim.NIL`. Both count, because a `nil`
--- returned from the child arrives in the host as `vim.NIL`: msgpack carries
--- nil as a value, and a Lua table cannot hold `nil`.
--- @param value any
--- @param msg? string
function M.is_nil(value, msg)
  if value == nil or value == vim.NIL then return end
  fail('is_nil', msg, 'expected nil or vim.NIL', value, nil)
end

--- Check identity with `==`, so two tables pass only when they are the same
--- table. Use `deep_equal` to compare contents.
--- @param got any
--- @param want any
--- @param msg? string
function M.equal(got, want, msg)
  if got == want then return end
  local note = with_types(got, want, 'expected the same value')
  if vim.deep_equal(got, want) then
    note = 'expected the same table, got two deep-equal tables (use deep_equal)'
  end
  fail('equal', msg, note, got, want)
end

--- @param got any
--- @param want any
--- @param msg? string
function M.not_equal(got, want, msg)
  if got ~= want then return end
  fail('not_equal', msg, 'expected different values, got the same value twice', got, want)
end

--- @param got any
--- @param want any
--- @param msg? string
function M.deep_equal(got, want, msg)
  if vim.deep_equal(got, want) then return end
  fail('deep_equal', msg, with_types(got, want, 'expected equal contents'), got, want)
end

--- @param got any
--- @param want any
--- @param msg? string
function M.not_deep_equal(got, want, msg)
  if not vim.deep_equal(got, want) then return end
  fail('not_deep_equal', msg, 'expected different contents, got equal ones', got, want)
end

--- @param list any[]
--- @param needle any
--- @return boolean
local function list_has(list, needle)
  for _, v in ipairs(list) do
    if vim.deep_equal(v, needle) then return true end
  end
  return false
end

--- Check that a string holds `needle` as a plain substring, or that a list
--- holds an element deep-equal to `needle`. Substrings are plain because `-`
--- and `+` are pattern quantifiers and are also what specs look for in diffs.
--- @param haystack string|any[]
--- @param needle any
--- @param msg? string
function M.contains(haystack, needle, msg)
  if type(haystack) ~= 'string' and type(haystack) ~= 'table' then
    error('contains: haystack must be a string or a list, got ' .. type(haystack), 2)
  end
  if type(haystack) == 'string' and type(needle) ~= 'string' then
    error('contains: a string haystack needs a string needle, got ' .. type(needle), 2)
  end
  if type(haystack) == 'string' and haystack:find(needle, 1, true) then return end
  if type(haystack) == 'table' and list_has(haystack, needle) then return end
  fail(
    'contains',
    msg,
    'expected the haystack (got) to contain the needle (want)',
    haystack,
    needle
  )
end

--- @param str string
--- @param pattern string  a Lua pattern
--- @param msg? string
function M.matches(str, pattern, msg)
  if type(str) ~= 'string' then error('matches: str must be a string, got ' .. type(str), 2) end
  if str:find(pattern) then return end
  fail('matches', msg, 'expected the string (got) to match the pattern (want)', str, pattern)
end

--- Check that `fn` raises, and return the error. When `expected` is given, the
--- error (inspected first when it is not a string) must hold it as a plain
--- substring.
--- @param fn function
--- @param expected? string
--- @param msg? string
--- @return any err
function M.raises(fn, expected, msg)
  local results = { pcall(fn) }
  if results[1] then
    local returned = { unpack(results, 2) }
    local note = 'expected the function to raise, but it returned (got)'
    fail('raises', msg, note, returned, expected or 'an error')
  end
  local err = results[2]
  if expected == nil then return err end
  local text = type(err) == 'string' and err or vim.inspect(err)
  if text:find(expected, 1, true) then return err end
  fail('raises', msg, 'expected the error (got) to contain the text (want)', text, expected)
end

-- Specs shadow busted's global with `local assert = require('test').assert`,
-- so calling the namespace keeps the built-in `assert(value, msg)` form
-- working. It is `ok`, inlined so `fail`'s level still lands on the spec.
setmetatable(M, {
  __call = function(_, value, msg)
    if not value then fail('ok', msg, 'expected a truthy value', value, true) end
    return value
  end,
})

return M
