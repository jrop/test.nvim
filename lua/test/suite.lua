--- The suite: spec files and the cases they declare. Loading a spec file runs
--- its `describe` bodies immediately, which builds a tree of scopes; each `it`
--- only records its function. A suite is every file's tree, with the cases
--- chosen from it. The executors in `test.executor` run a suite.
---
--- Every case gets an id: its place in the file's collection order. A run in
--- other processes (`--isolate`) collects each file once in the parent and
--- again in each worker, and the id is how the parent names a case to a
--- worker, so collection must build the same tree every time it runs.
local M = {}

--------------------------------------------------------------------------------
-- The tree
--------------------------------------------------------------------------------

--- @class test.suite.Scope
--- @field name string
--- @field parent test.suite.Scope?
--- @field before_all fun()[]
--- @field after_all fun()[]
--- @field before_each fun()[]
--- @field after_each fun()[]
--- @field children (test.suite.Scope|test.suite.Case)[]

--- @class test.suite.Case
--- @field id integer  the case's place in its file's collection order
--- @field name string
--- @field parent test.suite.Scope
--- @field fn fun()?  nil for a pending case

-- The scope `describe`, `it`, and the hooks add to, while a spec file loads,
-- and the file's cases so far, whose count gives the next case its id.
local collecting --- @type test.suite.Scope?
local collected = {} --- @type test.suite.Case[]

--- @param name string
--- @param parent test.suite.Scope?
--- @return test.suite.Scope
local function new_scope(name, parent)
  return {
    name = name,
    parent = parent,
    before_all = {},
    after_all = {},
    before_each = {},
    after_each = {},
    children = {},
  }
end

--- @param fn_name string
--- @return test.suite.Scope
local function current_scope(fn_name)
  if collecting then return collecting end
  error(fn_name .. ': no spec run is active; run spec files with `nvim -l <test.lua>`', 3)
end

--- Open a scope named `name` and collect what `fn` declares inside it.
--- @param name string
--- @param fn fun()
function M.describe(name, fn)
  local parent = current_scope 'describe'
  local scope = new_scope(name, parent)
  table.insert(parent.children, scope)
  collecting = scope
  -- The parent is restored even when `fn` raises, so the rest of the file is
  -- not collected into a scope that never closed. The error still propagates
  -- and fails the file.
  local ok, err = pcall(fn)
  collecting = parent
  if not ok then error(err, 0) end
end

--- Declare a case. It runs after the whole file has been collected.
--- @param name string
--- @param fn fun()
function M.it(name, fn)
  local scope = current_scope 'it'
  if type(fn) ~= 'function' then
    error(('it: %q needs a function; use pending for a case without one'):format(name), 2)
  end
  local case = { id = #collected + 1, name = name, parent = scope, fn = fn }
  collected[case.id] = case
  table.insert(scope.children, case)
end

--- Declare a case that is reported as pending instead of run.
--- @param name string
function M.pending(name)
  local scope = current_scope 'pending'
  local case = { id = #collected + 1, name = name, parent = scope }
  collected[case.id] = case
  table.insert(scope.children, case)
end

--- Run `fn` once, before the first case in the current scope runs, nested
--- scopes included.
--- @param fn fun()
function M.before_all(fn) table.insert(current_scope('before_all').before_all, fn) end

--- Run `fn` once, after the last case in the current scope has run, nested
--- scopes included, even when a case or a `before_all` hook failed.
--- @param fn fun()
function M.after_all(fn) table.insert(current_scope('after_all').after_all, fn) end

--- Run `fn` before each case in the current scope, nested scopes included.
--- @param fn fun()
function M.before_each(fn) table.insert(current_scope('before_each').before_each, fn) end

--- Run `fn` after each case in the current scope, nested scopes included,
--- even when the case failed.
--- @param fn fun()
function M.after_each(fn) table.insert(current_scope('after_each').after_each, fn) end

--------------------------------------------------------------------------------
-- Names and errors
--------------------------------------------------------------------------------

--- The names of a node's enclosing scopes and its own, joined by spaces. The
--- file's root scope has no name of its own, so its cases start at their
--- first `describe`.
--- @param node test.suite.Scope|test.suite.Case
--- @return string
function M.full_name(node)
  local names = {}
  local current = node --- @type (test.suite.Scope|test.suite.Case)?
  while current and current.parent do
    table.insert(names, 1, current.name)
    current = current.parent
  end
  return table.concat(names, ' ')
end

--- Call spec code `fn`, and return whether it succeeded and, when it did not,
--- the error and its full traceback. An error that is not a string is
--- inspected, because `debug.traceback` returns a non-string message as is.
--- @param fn function
--- @return boolean ok, string? err
function M.protect(fn)
  return xpcall(
    fn,
    function(e) return debug.traceback(type(e) == 'string' and e or vim.inspect(e), 2) end
  )
end

--- Load one spec file and collect its tree: its root scope, and its cases by
--- id. A file that fails to load or to collect has no root and no cases, and
--- the error instead.
--- @param path string
--- @return test.suite.Scope? root, table<integer, test.suite.Case> cases, string? err
local function collect(path)
  local root = new_scope(path)
  local chunk, load_err = loadfile(path)
  if not chunk then return nil, {}, load_err end
  local cases = {}
  collecting, collected = root, cases
  local ok, err = M.protect(chunk)
  collecting, collected = nil, {}
  if not ok then return nil, {}, err end
  return root, cases, nil
end

--------------------------------------------------------------------------------
-- The suite
--------------------------------------------------------------------------------

--- One spec file of a suite: its collected tree and the cases chosen from it,
--- or why it failed to load.
--- @class test.SuiteFile
--- @field path string
--- @field root? test.suite.Scope  nil when the file failed to load
--- @field cases table<integer, test.suite.Case>  by id, from 1; none when it failed
--- @field load_error? string
--- @field ids integer[]  the chosen cases, in collection order

--- Spec files and the cases chosen from them. Every file stays in a suite,
--- even with no case chosen, so the report still lists it and still reports
--- a file that failed to load.
--- @class test.Suite
--- @field files test.SuiteFile[]
local Suite = {}
Suite.__index = Suite
M.Suite = Suite

--- Collect every file, in order, with all of its cases chosen.
--- @param paths string[]
--- @return test.Suite
function Suite.collect(paths)
  local files = {}
  for _, path in ipairs(paths) do
    local root, cases, err = collect(path)
    local ids = vim.tbl_map(function(case) return case.id end, cases)
    files[#files + 1] = { path = path, root = root, cases = cases, load_error = err, ids = ids }
  end
  return setmetatable({ files = files }, Suite)
end

--- The same suite with only the chosen cases that `keep` accepts.
--- @param keep fun(case: test.suite.Case): boolean
--- @return test.Suite
function Suite:select(keep)
  local files = vim.tbl_map(function(file)
    local ids = vim.tbl_filter(function(id) return keep(file.cases[id]) end, file.ids)
    return vim.tbl_extend('force', file, { ids = ids })
  end, self.files)
  return setmetatable({ files = files }, Suite)
end

return M
