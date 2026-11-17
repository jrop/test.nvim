--- Spec collection and running. Loading a spec file runs its `describe`
--- bodies immediately, which builds a tree of scopes; each `it` only records
--- its function. Running then walks the tree in order: each scope runs its
--- `before_all` hooks before its first case and its `after_all` hooks after its
--- last, and each case runs inside its scopes' `before_each` and `after_each`
--- hooks.
local M = {}

--------------------------------------------------------------------------------
-- The tree
--------------------------------------------------------------------------------

--- @class test.runner.Scope
--- @field name string
--- @field parent test.runner.Scope?
--- @field before_all fun()[]
--- @field after_all fun()[]
--- @field before_each fun()[]
--- @field after_each fun()[]
--- @field children (test.runner.Scope|test.runner.Case)[]

--- @class test.runner.Case
--- @field name string
--- @field parent test.runner.Scope
--- @field fn fun()?  nil for a pending case

-- The scope `describe`, `it`, and the hooks add to, while a spec file loads.
local collecting --- @type test.runner.Scope?

--- @param name string
--- @param parent test.runner.Scope?
--- @return test.runner.Scope
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
--- @return test.runner.Scope
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
  table.insert(scope.children, { name = name, parent = scope, fn = fn })
end

--- Declare a case that is reported as pending instead of run.
--- @param name string
function M.pending(name)
  local scope = current_scope 'pending'
  table.insert(scope.children, { name = name, parent = scope })
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
--- @param node test.runner.Scope|test.runner.Case
--- @return string
local function full_name(node)
  local names = {}
  local current = node --- @type (test.runner.Scope|test.runner.Case)?
  while current and current.parent do
    table.insert(names, 1, current.name)
    current = current.parent
  end
  return table.concat(names, ' ')
end

--- Format an error for the report. The message comes first; traceback frames
--- follow only when they name the spec file, because frames inside the
--- library or a bundle point at code the reader did not write.
--- @param err any
--- @param trace string
--- @param path string
--- @return string
local function describe_error(err, trace, path)
  local message = type(err) == 'string' and err or vim.inspect(err)
  local frames = {}
  for line in trace:gmatch '[^\n]+' do
    if line:find(path, 1, true) then frames[#frames + 1] = line end
  end
  if #frames == 0 then return message end
  return message .. '\n' .. table.concat(frames, '\n')
end

--- Call `fn`, and return whether it succeeded and, when it did not, the
--- formatted error.
--- @param fn function
--- @param path string
--- @return boolean ok, string? err
local function protect(fn, path)
  return xpcall(fn, function(e) return describe_error(e, debug.traceback('', 2), path) end)
end

--------------------------------------------------------------------------------
-- The report
--------------------------------------------------------------------------------

--- @class test.runner.Failure
--- @field name string
--- @field message string  the error, with the traceback frames in the spec file

--- A case that takes longer than this prints its time beside its name, so the
--- slow cases stand out. 75 ms is mocha's default for a slow test.
local SLOW_MS = 75

--- The run's counts and its output: each outcome is counted and printed in
--- one step, so the two cannot disagree.
--- @class test.runner.Report
--- @field counts { passed: integer, failed: integer, pending: integer }
--- @field failures test.runner.Failure[]
--- @field paint test.color.Paint
local Report = {}
Report.__index = Report

--- @param paint test.color.Paint
--- @return test.runner.Report
function Report.new(paint)
  return setmetatable(
    { counts = { passed = 0, failed = 0, pending = 0 }, failures = {}, paint = paint },
    Report
  )
end

--- @param path string
function Report:file(path) io.stdout:write(self.paint('bold', path), '\n') end

--- The text after a case's name: its time, dim, when it ran longer than
--- `SLOW_MS`, and nothing otherwise.
--- @param ms number?  nil for a case that never ran, e.g. under a failed before_all
--- @return string
function Report:duration(ms)
  if not ms then return '' end
  -- Comparing the rounded time keeps the rule and the printed number in
  -- agreement: 75.4 ms would otherwise print as a slow `(75ms)`.
  local shown = math.floor(ms + 0.5)
  if shown <= SLOW_MS then return '' end
  return ' ' .. self.paint('dim', ('(%dms)'):format(shown))
end

--- @param name string
--- @param ms number  the case's time, with its before_each and after_each hooks
function Report:pass(name, ms)
  self.counts.passed = self.counts.passed + 1
  io.stdout:write('  ', self.paint('green', '✓'), ' ', name, self:duration(ms), '\n')
end

--- @param name string
--- @param message string
--- @param ms? number  the case's time, with its hooks; nil when it never ran
function Report:fail(name, message, ms)
  self.counts.failed = self.counts.failed + 1
  table.insert(self.failures, { name = name, message = message })
  io.stdout:write('  ', self.paint('red', '✗'), ' ', name, self:duration(ms), '\n')
end

--- A spec file that failed to load or to collect: one failure, named after
--- the file.
--- @param path string
--- @param message string
function Report:load_error(path, message)
  self.counts.failed = self.counts.failed + 1
  table.insert(self.failures, { name = path, message = message })
  io.stdout:write('  ', self.paint('red', '✗'), ' (the file did not load)\n')
end

--- @param name string
function Report:pending(name)
  self.counts.pending = self.counts.pending + 1
  io.stdout:write('  ', self.paint('yellow', '- ' .. name .. ' (pending)'), '\n')
end

--- Color a failure message's diff: `-` lines red, `+` lines green, and the
--- `--- got` and `+++ want` headers dim.
--- @param message string
--- @return string
function Report:diff_colors(message)
  local lines = {}
  for line in (message .. '\n'):gmatch '(.-)\n' do
    if line == '--- got' or line == '+++ want' then
      line = self.paint('dim', line)
    elseif line:sub(1, 2) == '- ' then
      line = self.paint('red', line)
    elseif line:sub(1, 2) == '+ ' then
      line = self.paint('green', line)
    end
    lines[#lines + 1] = line
  end
  return table.concat(lines, '\n')
end

--- Print every failure in full, then the counts.
--- @param seconds number
function Report:summary(seconds)
  for _, failure in ipairs(self.failures) do
    io.stdout:write(
      '\n',
      self.paint('red', self.paint('bold', '✗ ' .. failure.name)),
      '\n',
      self:diff_colors(failure.message),
      '\n'
    )
  end
  --- @param count integer
  --- @param word string
  --- @param style test.color.Style
  local function count_of(count, word, style)
    local text = ('%d %s'):format(count, word)
    return count > 0 and self.paint(style, text) or text
  end
  io.stdout:write(
    '\n',
    count_of(self.counts.passed, 'passed', 'green'),
    ', ',
    count_of(self.counts.failed, 'failed', 'red'),
    ', ',
    count_of(self.counts.pending, 'pending', 'yellow'),
    ('%s\n'):format(self.paint('dim', (' in %.2fs'):format(seconds)))
  )
end

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

--- The scopes from the file's root down to the case's own scope.
--- @param case test.runner.Case
--- @return test.runner.Scope[]
local function scopes_of(case)
  local scopes = {}
  local scope = case.parent --- @type test.runner.Scope?
  while scope do
    table.insert(scopes, 1, scope)
    scope = scope.parent
  end
  return scopes
end

--- Run one case with its `before_each` and `after_each` hooks, and record its
--- outcome. Before-hooks run from the outermost scope inward, and a failing
--- one skips the rest and the case; after-hooks run from the innermost scope
--- outward, always.
--- @param case test.runner.Case
--- @param path string
--- @param report test.runner.Report
local function run_case(case, path, report)
  local name = full_name(case)
  if not case.fn then return report:pending(name) end

  local started = vim.uv.hrtime()
  local errors = {}
  --- @param fn fun()
  --- @return boolean
  local function attempt(fn)
    local ok, err = protect(fn, path)
    if not ok then errors[#errors + 1] = err end
    return ok
  end

  local scopes = scopes_of(case)
  local ready = true
  for _, scope in ipairs(scopes) do
    for _, hook in ipairs(scope.before_each) do
      ready = ready and attempt(hook)
    end
  end
  if ready then attempt(case.fn) end
  for i = #scopes, 1, -1 do
    for _, hook in ipairs(scopes[i].after_each) do
      attempt(hook)
    end
  end

  local ms = (vim.uv.hrtime() - started) / 1e6
  if #errors == 0 then return report:pass(name, ms) end
  report:fail(name, table.concat(errors, '\n\n'), ms)
end

--- Whether `filter`, a plain substring of the full case name, selects `case`.
--- @param case test.runner.Case
--- @param filter string?
--- @return boolean
local function selected(case, filter)
  return not filter or full_name(case):find(filter, 1, true) ~= nil
end

--- The cases under `scope`, nested scopes included, that `filter` selects.
--- @param scope test.runner.Scope
--- @param filter string?
--- @param out? test.runner.Case[]
--- @return test.runner.Case[]
local function selected_cases(scope, filter, out)
  out = out or {}
  for _, child in ipairs(scope.children) do
    if child.children then
      selected_cases(child --[[@as test.runner.Scope]], filter, out)
    elseif
      selected(child --[[@as test.runner.Case]], filter)
    then
      out[#out + 1] = child --[[@as test.runner.Case]]
    end
  end
  return out
end

--- Run a scope's selected cases between its `before_all` and `after_all`
--- hooks. A scope with nothing selected runs neither hook. A failing
--- `before_all` skips the rest of the scope and fails each selected case with
--- its error; `after_all` still runs, so it can undo a partial setup.
--- @param scope test.runner.Scope
--- @param path string
--- @param filter string?
--- @param report test.runner.Report
local function run_scope(scope, path, filter, report)
  local cases = selected_cases(scope, filter)
  if #cases == 0 then return end
  -- A hook failure is reported under the scope's name, or the file's for the
  -- root scope.
  local scope_name = scope.parent and full_name(scope) or path

  local setup_err --- @type string?
  for _, hook in ipairs(scope.before_all) do
    local ok, err = protect(hook, path)
    if not ok then
      setup_err = ('before_all in %s failed:\n%s'):format(scope_name, err)
      break
    end
  end

  if setup_err then
    for _, case in ipairs(cases) do
      if case.fn then
        report:fail(full_name(case), setup_err)
      else
        report:pending(full_name(case))
      end
    end
  else
    for _, child in ipairs(scope.children) do
      if child.children then
        run_scope(child --[[@as test.runner.Scope]], path, filter, report)
      elseif
        selected(child --[[@as test.runner.Case]], filter)
      then
        run_case(child --[[@as test.runner.Case]], path, report)
      end
    end
  end

  for _, hook in ipairs(scope.after_all) do
    local ok, err = protect(hook, path)
    if not ok then
      report:fail(scope_name .. ' (after_all)', err --[[@as string]])
    end
  end
end

--- Load one spec file and collect its tree. A file that fails to load or to
--- collect is reported as one failure, and its cases do not run.
--- @param path string
--- @return test.runner.Scope?, string?
local function collect(path)
  local root = new_scope(path)
  local chunk, load_err = loadfile(path)
  if not chunk then return nil, load_err end
  collecting = root
  local ok, err = protect(chunk, path)
  collecting = nil
  if not ok then return nil, err end
  return root
end

--- @param path string
--- @param filter string?  a plain substring of the full case name
--- @param report test.runner.Report
local function run_file(path, filter, report)
  -- Modules a file loads are dropped after it, so one file's module state
  -- (a cache, a counter, a patched function) cannot leak into the next.
  local loaded_before = {}
  for name in pairs(package.loaded) do
    loaded_before[name] = true
  end

  report:file(path)
  local root, err = collect(path)
  if root then
    run_scope(root, path, filter, report)
  else
    report:load_error(path, err --[[@as string]])
  end

  for name in pairs(package.loaded) do
    if not loaded_before[name] then package.loaded[name] = nil end
  end
end

--- Run every file in order, print a report, and return it.
--- @param paths string[]
--- @param opts { filter?: string, paint: test.color.Paint }
--- @return test.runner.Report
function M.run(paths, opts)
  local report = Report.new(opts.paint)
  local started = vim.uv.hrtime()
  for _, path in ipairs(paths) do
    run_file(path, opts.filter, report)
  end
  report:summary((vim.uv.hrtime() - started) / 1e9)
  return report
end

return M
