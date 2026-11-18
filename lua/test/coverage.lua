-- `record_lines`, `export_hits`, and `write_at_exit` run inside each process
-- being measured: the host, every child, and every script. Children and
-- scripts do not load this library, so those functions cannot reach a
-- module's locals, and a process's hits live in its global
-- `__test_coverage_hits`: `__test_coverage_hits[source][line]` is true once
-- `line` of the chunk named `source` has run. Only that process's own hook
-- writes the table, and only `export_hits` reads it.
--- @diagnostic disable: global-in-non-module

--- Line coverage without dependencies. A line hook records every line that
--- runs, in the host and in every child editor, and `jit.util` lists the lines
--- that hold code, which is the denominator of each file's percentage.
---
--- A plugin's code mostly runs in other processes: the children and the
--- scripts. Every such process gets its hits back to the host the same way:
--- `argv` installs the hook through `--cmd`, and the process writes its hits
--- into the run's directory as it exits. A process that crashes, or that is
--- still running when the run stops, loses its hits.
local M = {}

--- One process's hits, as `export_hits` lists them: `{ path, lines }` pairs,
--- with each file's absolute path, a shape that survives JSON.
--- @alias test.coverage.Export [string, integer[]][]

--- The open run's directory, from `start` to `stop`; nil when not recording.
--- Each process measured during the run writes one file into it.
--- @type string?
local run_dir

--- The line hook that was installed when the open run started, as
--- `debug.gethook` returns it, so `stop` can put it back. A run nests inside
--- another when a spec runs the CLI with `--coverage` through `Nvim.script`,
--- whose `--cmd` has already installed the outer run's hook.
--- @type [function?, string?, integer?]
local prior_hook = {}

--- Install the line hook in the running editor. The same function runs in the
--- host and, through `--cmd`, in each other process, so it has no upvalues.
local function record_lines()
  _G.__test_coverage_hits = _G.__test_coverage_hits or {}
  local hits = _G.__test_coverage_hits
  -- The type stubs declare only the form that takes a thread first.
  --- @diagnostic disable-next-line: param-type-mismatch
  debug.sethook(function(_, line)
    -- A line hook never fires inside itself.
    -- luacov: disable
    local info = debug.getinfo(2, 'S')
    if not info then return end
    local lines = hits[info.source]
    if not lines then
      lines = {}
      hits[info.source] = lines
    end
    lines[line] = true
    -- luacov: enable
  end, 'l')
end

--- Stop recording in the running editor and list its hits per file. It runs
--- in other processes, so it has no upvalues.
--- @return test.coverage.Export
local function export_hits()
  -- Turning the hook off first keeps it from adding this function's own
  -- source to the table while the loop below walks it.
  debug.sethook()
  -- luacov: disable
  local out = {}
  for source, lines in pairs(_G.__test_coverage_hits) do
    -- A chunk name that starts with `@` names a file, often relative to this
    -- process's cwd, which another process does not know. So the path is made
    -- absolute here, where the cwd is right -- unless the process changed
    -- directory after loading the file. Other chunk names are strings, which
    -- no report row can match.
    if source:sub(1, 1) == '@' then
      local path = vim.fs.normalize(vim.fn.fnamemodify(source:sub(2), ':p'))
      out[#out + 1] = { path, vim.tbl_keys(lines) }
    end
  end
  return out
  -- luacov: enable
end

--- Write the process's hits into `dir` as JSON when it exits, in a file named
--- after its pid, so processes never share a file. `VimLeavePre` covers a
--- child that is stopped and a script that returns. `os.exit` -- under normal
--- circumstances, a script's way to set its exit status -- skips
--- `VimLeavePre`, so the hits are also written just before the real `os.exit`
--- runs. It runs in the process, so it has no upvalues; `export` is
--- `export_hits`, loaded there.
--- @param dir string
--- @param export fun(): test.coverage.Export
local function write_at_exit(dir, export)
  local function write()
    local f = io.open(('%s/%d.json'):format(dir, vim.fn.getpid()), 'w')
    if not f then return end
    f:write(vim.json.encode(export()))
    -- `export` has turned the hook off.
    -- luacov: disable
    f:close()
    -- luacov: enable
  end
  local exit = os.exit
  --- @diagnostic disable-next-line: duplicate-set-field
  os.exit = function(...)
    write()
    -- `write` has turned the hook off.
    -- luacov: disable
    return exit(...)
    -- luacov: enable
  end
  vim.api.nvim_create_autocmd('VimLeavePre', { callback = write })
end

--- A Lua expression that loads `f` from its bytecode. Every byte outside
--- printable ASCII is escaped, so the expression can sit in one argv entry
--- and on one Ex command line.
--- @param f function
--- @return string
local function loader(f)
  local escaped = string
    .dump(f)
    :gsub('[%z%c"\\\128-\255]', function(c) return ('\\%03d'):format(c:byte()) end)
  return ('loadstring("%s")'):format(escaped)
end

--- Start recording lines in the host, and in every process that `argv`
--- instruments from now on.
function M.start()
  prior_hook = { debug.gethook() }
  run_dir = vim.fn.tempname()
  vim.fn.mkdir(run_dir, 'p')
  record_lines()
end

--- The Neovim arguments that record a new process's lines into the open run,
--- or none when not recording. They go before any other argument: `--cmd`
--- runs before the user's config and before a `-l` script's first line, so
--- the hook is in place before any of a plugin's code can load.
---
--- The open run is this process's own, or else the run that instrumented
--- this process, whose directory the `--cmd` left in the global
--- `__test_coverage_dir`. So a process a run measures also measures the
--- processes it starts, such as an isolated worker's child editors.
--- @return string[]
function M.argv()
  local dir = run_dir or _G.__test_coverage_dir
  if not dir then return {} end
  local chunk = ('lua __test_coverage_dir = %q; %s(); %s(%q, %s)'):format(
    dir,
    loader(record_lines),
    loader(write_at_exit),
    dir,
    loader(export_hits)
  )
  return { '--cmd', chunk }
end

--- Stop recording, delete the run's directory, and return every process's
--- hits, the host's included. The hook that was installed before `start`
--- comes back, so an outer run keeps recording, e.g. through this run's report.
--- @return test.coverage.Export[]
function M.stop()
  local dir = assert(run_dir, 'coverage.stop: not recording')
  run_dir = nil
  local run = { export_hits() }
  -- `export_hits` has turned the hook off, and this line turns it back on.
  -- The type stubs declare only the form that takes a thread first.
  -- luacov: disable
  --- @diagnostic disable-next-line: param-type-mismatch
  debug.sethook(unpack(prior_hook))
  -- luacov: enable
  for _, path in ipairs(vim.fn.glob(dir .. '/*.json', true, true)) do
    -- A process killed partway through its write leaves a truncated file,
    -- which does not decode. Losing that one process's hits is better than
    -- failing the whole report.
    local ok, export = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
    if ok and type(export) == 'table' then run[#run + 1] = export end
  end
  vim.fn.delete(dir, 'rf')
  return run
end

--------------------------------------------------------------------------------
-- The report
--------------------------------------------------------------------------------

--- The lines of a file that hold code: every line that some bytecode
--- instruction belongs to, in the main chunk and every function nested in it.
--- Returns nil, and the load error, for a file that does not load.
---
--- A function that ends in `error(...)` never runs the return on its closing
--- `end`, yet the line needs no special case: LuaJIT puts the enclosing
--- function's `FNEW`, which creates the function, on that same line, so the
--- line runs whenever the definition does.
--- @param path string
--- @return table<integer, true>?, string?
local function executable_lines(path)
  local chunk, err = loadfile(path)
  if not chunk then return nil, err end
  local util = require 'jit.util'
  local lines = {}
  --- @param fn function
  local function walk(fn)
    local pc = 1
    while util.funcbc(fn, pc) do
      local line = util.funcinfo(fn, pc).currentline
      if line then lines[line] = true end
      pc = pc + 1
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

--- The lines between a `-- luacov: disable` line and the next
--- `-- luacov: enable` line, or the end of the file. These are luacov's
--- markers, so code already marked for luacov needs no change. A marker is a
--- whole line, as in luacov, so prose that mentions one, such as this comment,
--- does not count as one.
--- @param path string
--- @return table<integer, true>
local function disabled_lines(path)
  local disabled, off = {}, false
  for i, text in ipairs(vim.fn.readfile(path)) do
    local marker = text:match '^%s*%-%-%s*luacov:%s*(%a+)%s*$'
    if marker == 'disable' then
      off = true
    elseif marker == 'enable' then
      off = false
    elseif off then
      disabled[i] = true
    end
  end
  return disabled
end

--- Union every process's hits per file. One file can run in several
--- processes, and under several chunk names in one process (relative, or
--- absolute), so this is the one place hits are combined.
--- @param run test.coverage.Export[]
--- @return table<string, table<integer, true>>
local function hits_by_path(run)
  local by_path = {}
  for _, export in ipairs(run) do
    for _, entry in ipairs(export) do
      local merged = by_path[entry[1]] or {}
      by_path[entry[1]] = merged
      for _, line in ipairs(entry[2]) do
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

--- Print one row per file: its covered share of executable lines, except the
--- disabled ones, and the
--- lines that never ran, or why the file could not be measured. Then print
--- the total. A fully covered share prints green and a partial one yellow;
--- text is padded before it is painted, so escape codes do not break the
--- columns.
--- @param run test.coverage.Export[]  every process's hits, as `stop` returns them
--- @param paths string[]  the files to report, relative to the cwd
--- @param paint test.color.Paint
function M.report(run, paths, paint)
  local by_path = hits_by_path(run)
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
      for line in pairs(disabled_lines(path)) do
        executable[line] = nil
      end
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
