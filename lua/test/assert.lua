--- Value assertions: deep equality with a readable line diff.
--- @class test.assert
local M = {}

--- Compute the edit operations turning `a` into `b`, one optimal script.
--- Operations:
---   '='  keep (got line matches want line)
---   '-'  delete a got line
---   '+'  insert a want line
--- A substitution surfaces as a `-` immediately followed by a `+`, which is
--- exactly the change rendering the diff asks for.
--- @param a string[] -- got lines
--- @param b string[] -- want lines
--- @return {op: string, line: string}[]
local function edit_ops(a, b)
  local m, n = #a, #b
  -- Pre-allocate every cell to 0 so all entries are concrete integers;
  -- then overwrite row 0, column 0, and the interior in turn.
  -- Keyed by integer, not an array type: every cell is written before it is
  -- read, and a map type says so without re-narrowing each index.
  local dp = {} --- @type table<integer, table<integer, integer>>
  for i = 0, m do
    dp[i] = {}
    for j = 0, n do
      dp[i][j] = 0
    end
    dp[i][0] = i
  end
  for j = 1, n do
    dp[0][j] = j
  end
  for i = 1, m do
    for j = 1, n do
      if a[i] == b[j] then
        dp[i][j] = dp[i - 1][j - 1]
      else
        local del = dp[i - 1][j] + 1
        local ins = dp[i][j - 1] + 1
        local sub = dp[i - 1][j - 1] + 1
        local min = del
        if ins < min then min = ins end
        if sub < min then min = sub end
        dp[i][j] = min
      end
    end
  end

  -- Walk the table back from the bottom-right corner. Each step reads the
  -- neighbour the current cost was derived from, so the emitted operations
  -- are one optimal edit script, in reverse.
  local ops = {} --- @type {op: string, line: string}[]
  local i, j = m, n
  while i > 0 or j > 0 do
    if i > 0 and j > 0 and a[i] == b[j] then
      table.insert(ops, { op = '=', line = a[i] })
      i = i - 1
      j = j - 1
    elseif i == 0 or (j > 0 and dp[i][j - 1] <= dp[i - 1][j]) then
      -- Insert. Prefer insert over delete on ties so that, after reversing,
      -- a substitution renders as `-` (delete) then `+` (insert).
      table.insert(ops, { op = '+', line = b[j] })
      j = j - 1
    else
      table.insert(ops, { op = '-', line = a[i] })
      i = i - 1
    end
  end
  -- Reverse to source order.
  local rev = {} --- @type {op: string, line: string}[]
  for k = #ops, 1, -1 do
    rev[#rev + 1] = ops[k]
  end
  return rev
end

--- Build a readable unified line diff of two line lists. `+` = add (want
--- line), `-` = delete (got line); a change surfaces as `-` then `+` on
--- consecutive lines.
--- @param got string[]
--- @param want string[]
--- @return string
function M.diff(got, want)
  local ops = edit_ops(got, want)
  local out = { '--- got', '+++ want' }
  for _, o in ipairs(ops) do
    if o.op == '=' then
      table.insert(out, '  ' .. o.line)
    elseif o.op == '-' then
      table.insert(out, '- ' .. o.line)
    else -- '+': add (want line)
      table.insert(out, '+ ' .. o.line)
    end
  end
  return table.concat(out, '\n')
end

--- Deep-equality. On mismatch prints a unified diff of the two values
--- (pretty-printed via vim.inspect) and calls error().
--- @param got any
--- @param want any
--- @param msg? string
function M.deep_equal(got, want, msg)
  if vim.deep_equal(got, want) then return end
  local header = msg and ('deep_equal failed: ' .. msg) or 'deep_equal failed'
  local got_lines = vim.split(vim.inspect(got), '\n')
  local want_lines = vim.split(vim.inspect(want), '\n')
  error(('%s\n%s'):format(header, M.diff(got_lines, want_lines)), 2)
end

return M
