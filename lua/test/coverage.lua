-- `record_lines` and the function `collect` sends also run in the children,
-- which do not load this library, so they cannot reach a module's locals.
-- Their table is the global `__test_coverage_hits`, in the host and in every
-- child alike: `__test_coverage_hits[source][line]` is true once `line` of the
-- chunk named `source` has run.
--- @diagnostic disable: global-in-non-module

--- Line coverage without dependencies. A line hook records every line that
--- runs, in the host and in every child editor, and `jit.util` lists the lines
--- that hold code, which is the denominator of each file's percentage.
---
--- A plugin's code mostly runs in the children, so each child installs the
--- same hook when it starts, and `Nvim:stop()` reads its hits back before
--- stopping it. A child that crashes or is never stopped loses its hits.
local M = {}

local recording = false

--- Install the line hook in the running editor. The same function runs in the
--- host and, through `Nvim:run`, in each child, so it has no upvalues.
local function record_lines()
  _G.__test_coverage_hits = _G.__test_coverage_hits or {}
  local hits = _G.__test_coverage_hits
  -- The type stubs declare only the form that takes a thread first.
  --- @diagnostic disable-next-line: param-type-mismatch
  debug.sethook(function(_, line)
    local info = debug.getinfo(2, 'S')
    if not info then return end
    local lines = hits[info.source]
    if not lines then
      lines = {}
      hits[info.source] = lines
    end
    lines[line] = true
  end, 'l')
end

--- Start recording lines in the host, and in every child started from now on.
function M.start()
  recording = true
  record_lines()
end

--- Stop recording.
function M.stop()
  debug.sethook()
  recording = false
end

--- Record lines in a newly started child, when recording. `Nvim.start` calls
--- this before it adds the plugin to the child's runtimepath, so the hook is
--- in place before any of the plugin's code can load.
--- @param nv test.Nvim
function M.start_in(nv)
  if recording then nv:run(record_lines) end
end

--- Read a child's hits back and merge them. Does nothing when not recording,
--- or when the child no longer answers.
--- @param nv test.Nvim
function M.collect(nv)
  if not recording then return end
  local ok, sources = pcall(nv.run, nv, function()
    -- Turning the hook off first keeps it from adding this function's own
    -- source to the table while the loop below walks it.
    debug.sethook()
    local out = {}
    for source, lines in pairs(_G.__test_coverage_hits) do
      out[#out + 1] = { source, vim.tbl_keys(lines) }
    end
    return out
  end)
  if not ok or type(sources) ~= 'table' then return end
  for _, entry in ipairs(sources) do
    local lines = _G.__test_coverage_hits[entry[1]] or {}
    _G.__test_coverage_hits[entry[1]] = lines
    for _, line in ipairs(entry[2]) do
      lines[line] = true
    end
  end
end

--------------------------------------------------------------------------------
-- The report
--------------------------------------------------------------------------------

--- @param ins integer  a bytecode instruction, as `jit.util.funcbc` returns it
--- @return string
local function opcode_name(ins)
  local op = bit.band(ins, 0xff)
  return (require('jit.vmdef').bcnames:sub(op * 6 + 1, op * 6 + 6):gsub('%s+$', ''))
end

--- The lines of a file that hold code: every line that some bytecode
--- instruction belongs to, in the main chunk and every function nested in it.
--- Returns nil, and the load error, for a file that does not load.
---
--- A function's closing `end` line is left out when its only instruction is
--- the implicit `RET0`. After a final `error(...)`, that instruction can never
--- run, so the line would always show as missed; after a fall-through, the
--- line before `end` already shows whether the function got that far.
--- @param path string
--- @return table<integer, true>?, string?
local function executable_lines(path)
  local chunk, err = loadfile(path)
  if not chunk then return nil, err end
  local util = require 'jit.util'
  local lines = {}
  --- @param fn function
  local function walk(fn)
    local info = util.funcinfo(fn)
    local ops_by_line = {} --- @type table<integer, string[]>
    local pc = 1
    while util.funcbc(fn, pc) do
      local line = util.funcinfo(fn, pc).currentline
      if line then
        ops_by_line[line] = ops_by_line[line] or {}
        table.insert(ops_by_line[line], opcode_name(util.funcbc(fn, pc)))
      end
      pc = pc + 1
    end
    for line, ops in pairs(ops_by_line) do
      local implicit_end = line == info.lastlinedefined
        and line > info.linedefined
        and #ops == 1
        and ops[1] == 'RET0'
      if not implicit_end then lines[line] = true end
    end
    -- Negative constant indices hold a function's nested prototypes.
    local i = -1
    while true do
      local constant = util.funck(fn, i)
      if constant == nil then break end
      if type(constant) == 'proto' then walk(constant) end
      i = i - 1
    end
  end
  walk(chunk)
  return lines
end

--- Merge the hits of every chunk named after `path`, however the chunk name
--- spelled it (relative to the cwd, or absolute).
--- @return table<string, table<integer, true>>
local function hits_by_path()
  local by_path = {}
  for source, lines in pairs(_G.__test_coverage_hits or {}) do
    if source:sub(1, 1) == '@' then
      local path = vim.fs.normalize(vim.fn.fnamemodify(source:sub(2), ':p'))
      local merged = by_path[path] or {}
      by_path[path] = merged
      for line in pairs(lines) do
        merged[line] = true
      end
    end
  end
  return by_path
end

--- Compress sorted line numbers into ranges, such as `3, 7-9`.
--- @param lines integer[]
--- @return string
local function ranges(lines)
  local out = {}
  --- @param first integer
  --- @param last integer
  local function add(first, last)
    out[#out + 1] = first == last and tostring(first) or (first .. '-' .. last)
  end
  local first, last --- @type integer?, integer?
  for _, line in ipairs(lines) do
    if last and line == last + 1 then
      last = line
    else
      if first and last then add(first, last) end
      first, last = line, line
    end
  end
  if first and last then add(first, last) end
  return table.concat(out, ', ')
end

--- Print one row per file: its covered share of executable lines, and the
--- lines that never ran, or why the file could not be measured. Then print
--- the total. A fully covered share prints green and a partial one yellow;
--- text is padded before it is painted, so escape codes do not break the
--- columns.
--- @param paths string[]  the files to report, relative to the cwd
--- @param paint test.color.Paint
function M.report(paths, paint)
  local by_path = hits_by_path()
  --- @type { name: string, hit: integer, count: integer, note: string, loaded: boolean }[]
  local rows = {}
  local total_hit, total_lines = 0, 0
  for _, path in ipairs(paths) do
    local executable, err = executable_lines(path)
    if not executable then
      rows[#rows + 1] = {
        name = path,
        hit = 0,
        count = 0,
        note = 'did not load: ' .. tostring(err),
        loaded = false,
      }
    else
      local hits = by_path[vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))] or {}
      local missed, hit, count = {}, 0, 0
      for line in pairs(executable) do
        count = count + 1
        if hits[line] then
          hit = hit + 1
        else
          missed[#missed + 1] = line
        end
      end
      table.sort(missed)
      total_hit, total_lines = total_hit + hit, total_lines + count
      local note = #missed > 0 and ('missed: ' .. ranges(missed)) or ''
      rows[#rows + 1] = { name = path, hit = hit, count = count, note = note, loaded = true }
    end
  end
  rows[#rows + 1] =
    { name = 'total', hit = total_hit, count = total_lines, note = '', loaded = true }

  local width = 0
  for _, row in ipairs(rows) do
    width = math.max(width, #row.name)
  end

  io.stdout:write('\n', paint('bold', 'Coverage'), '\n')
  for _, row in ipairs(rows) do
    local share = ('%6.1f%%'):format(row.count == 0 and 100 or row.hit / row.count * 100)
    local style = row.hit == row.count and 'green' or 'yellow' --- @type test.color.Style
    if not row.loaded then
      share, style = '      -', 'red'
    end
    local line = ('  %-' .. width .. 's %s  %d/%d'):format(
      row.name,
      paint(style, share),
      row.hit,
      row.count
    )
    if row.note ~= '' then line = line .. paint('dim', '  ' .. row.note) end
    io.stdout:write(line, '\n')
  end
end

return M
