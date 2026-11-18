--- The report: it consumes a run's events and prints them, and it counts each
--- outcome in the same step that prints it, so the two cannot disagree.

--- @class test.report.Failure
--- @field name string
--- @field message string  the error, with the traceback frames in the spec file
--- @field output? string  what the case printed, when it ran in a worker

--- A case that takes longer than this prints its time beside its name, so the
--- slow cases stand out. 75 ms is mocha's default for a slow test.
local SLOW_MS = 75

--- @class test.Report
--- @field counts { passed: integer, failed: integer, pending: integer }
--- @field failures test.report.Failure[]
--- @field paint test.color.Paint
--- @field started integer  `vim.uv.hrtime()` when the run began, for the summary's time
local Report = {}
Report.__index = Report

--- @param paint test.color.Paint
--- @return test.Report
function Report.new(paint)
  return setmetatable({
    counts = { passed = 0, failed = 0, pending = 0 },
    failures = {},
    paint = paint,
    started = vim.uv.hrtime(),
  }, Report)
end

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

--- Count a failure, keep it for the summary, and print its line.
--- @param failure test.report.Failure
--- @param line string  the text after the mark
function Report:failed(failure, line)
  self.counts.failed = self.counts.failed + 1
  table.insert(self.failures, failure)
  io.stdout:write('  ', self.paint('red', '✗'), ' ', line, '\n')
end

--- Print one event. A case starting prints nothing; only its outcome does.
-- The union is spelled out because emmylua narrows a parameter on `kind` only
-- when its type is written inline, not through the `test.dto.Event` alias.
--- @param event test.dto.FileEvent|test.dto.LoadErrorEvent|test.dto.StartEvent|test.dto.PassEvent|test.dto.FailEvent|test.dto.PendingEvent
function Report:event(event)
  if event.kind == 'file' then
    io.stdout:write(self.paint('bold', event.path), '\n')
  elseif event.kind == 'load_error' then
    self:failed({ name = event.path, message = event.message }, '(the file did not load)')
  elseif event.kind == 'pass' then
    self.counts.passed = self.counts.passed + 1
    io.stdout:write(
      '  ',
      self.paint('green', '✓'),
      ' ',
      event.name,
      self:duration(event.ms),
      '\n'
    )
  elseif event.kind == 'fail' then
    self:failed(
      { name = event.name, message = event.message, output = event.output },
      event.name .. self:duration(event.ms)
    )
  elseif event.kind == 'pending' then
    self.counts.pending = self.counts.pending + 1
    io.stdout:write('  ', self.paint('yellow', '- ' .. event.name .. ' (pending)'), '\n')
  end
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

--- Print every failure in full, then the counts and the run's time.
function Report:summary()
  local seconds = (vim.uv.hrtime() - self.started) / 1e9
  for _, failure in ipairs(self.failures) do
    io.stdout:write(
      '\n',
      self.paint('red', self.paint('bold', '✗ ' .. failure.name)),
      '\n',
      self:diff_colors(failure.message),
      '\n'
    )
    if failure.output then
      io.stdout:write(self.paint('dim', 'output:'), '\n', failure.output, '\n')
    end
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

return Report
