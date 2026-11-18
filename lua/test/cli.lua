--- The `nvim -l <test.lua>` command line: find the spec files, run them, and
--- turn the result into an exit status.
-- Only what parsing and recording need loads here; the runner loads after
-- coverage starts, so a coverage run of this repository counts its lines.
local args = require 'test.vendor.args'
local coverage = require 'test.coverage'

local M = {}

-- Whether `main` is running. A spec that requires the library during a run
-- executes test/init.lua again, which asks this before starting a second run.
local running = false

--- @return boolean
function M.running() return running end

local USAGE = [[
Usage: nvim -l <test.lua> [<path or glob>...] [options]

Runs spec files. A directory includes every `*_spec.lua` file under it, a file
includes itself, and anything else is a glob matched against paths relative to
the current directory. With no paths, runs `spec/`.

Options:
  --exclude <glob>   Skip paths matching <glob> (repeatable)
  --filter <text>    Run only cases whose full name contains <text>
  --coverage         Report line coverage of lua/**/*.lua, vendor/ excluded,
                     counting lines run in the host and in every child
  --isolate <unit>   Run each spec file (<unit> = file) or each case
                     (<unit> = case) in its own process, in parallel
  -j, --jobs <n>     Run at most <n> processes at once (default: the number
                     of CPUs); implies --isolate file
  --timeout <ms>     Kill an isolated process that reports nothing for <ms>,
                     and fail the case it was running (needs --isolate or -j)
  --color            Color the output even when stdout is not a terminal
  -h, --help         Show this help

Examples:
  nvim -l lua/myplugin/vendor/test.lua
  nvim -l lua/myplugin/vendor/test.lua spec/ui --filter 'renders'
  nvim -l lua/myplugin/vendor/test.lua 'spec/**/*_spec.lua' --exclude 'spec/slow/**'
  nvim -l lua/myplugin/vendor/test.lua --isolate case --timeout 5000
]]

--- @type table<string, any>
local ARGS_SPEC = {
  ['--exclude'] = { 'string' },
  ['--filter'] = 'string',
  ['--coverage'] = 'boolean',
  ['--isolate'] = 'string',
  ['--jobs'] = 'number',
  ['-j'] = '--jobs',
  ['--timeout'] = 'number',
  ['--color'] = 'boolean',
  -- Internal, so not in the usage: an isolated run starts each worker with it.
  ['--worker'] = 'string',
  ['--help'] = 'boolean',
  ['-h'] = '--help',
}

--- @param glob string
--- @return vim.lpeg.Pattern
local function compile(glob)
  local ok, pattern = pcall(vim.glob.to_lpeg, glob)
  if not ok then error(('invalid glob %q: %s'):format(glob, pattern), 0) end
  return pattern
end

--- @param path string
--- @param patterns vim.lpeg.Pattern[]
--- @return boolean
local function matches_any(path, patterns)
  for _, pattern in ipairs(patterns) do
    if pattern:match(path) then return true end
  end
  return false
end

--- Every file under `dir`, as paths that start with `dir`.
--- @param dir string
--- @return string[]
local function files_under(dir)
  local out = {}
  -- math.huge is unbounded, but emmylua types `depth` as integer.
  --- @diagnostic disable-next-line: param-type-mismatch
  for rel, kind in vim.fs.dir(dir, { depth = math.huge }) do
    if kind == 'file' then out[#out + 1] = vim.fs.joinpath(dir, rel) end
  end
  return out
end

--- The directory a glob's matches must live under: its path up to the first
--- segment that holds a wildcard.
--- @param glob string
--- @return string
local function glob_root(glob)
  local fixed = {}
  for segment in glob:gmatch '[^/]+' do
    if segment:find '[%*%?%[{]' then break end
    fixed[#fixed + 1] = segment
  end
  return #fixed == 0 and '.' or table.concat(fixed, '/')
end

--- Expand each include into spec files, drop the excluded ones, and return
--- the rest sorted and without duplicates.
--- @param includes string[]
--- @param excludes vim.lpeg.Pattern[]
--- @return string[]
local function find_specs(includes, excludes)
  local found = {} --- @type table<string, true>
  local function add(path)
    path = vim.fs.normalize(path)
    if not matches_any(path, excludes) then found[path] = true end
  end

  for _, include in ipairs(includes) do
    if vim.fn.filereadable(include) == 1 then
      add(include)
    else
      -- A directory means the spec files under it.
      local glob = vim.fn.isdirectory(include) == 1
          and vim.fs.joinpath(vim.fs.normalize(include), '**/*_spec.lua')
        or include
      local pattern = compile(glob)
      for _, path in ipairs(files_under(glob_root(glob))) do
        if pattern:match(vim.fs.normalize(path)) then add(path) end
      end
    end
  end

  local paths = vim.tbl_keys(found)
  table.sort(paths)
  return paths
end

--- Whether `path` is a type stub: a file that opens with `---@meta`, which
--- the language server reads and nothing ever runs.
--- @param path string
--- @return boolean
local function is_meta(path)
  local first = vim.fn.readfile(path, '', 1)[1] or ''
  return first:match '^%-%-%-%s*@meta' ~= nil
end

--- The plugin's own sources: every Lua file under `lua/`, except vendored
--- files, which belong to another project, and type stubs, which hold no code.
--- @return string[]
local function coverage_paths()
  if vim.fn.isdirectory 'lua' == 0 then return {} end
  local paths = vim.tbl_filter(
    function(path)
      return path:match '%.lua$' and not path:find('/vendor/', 1, true) and not is_meta(path)
    end,
    vim.tbl_map(vim.fs.normalize, files_under 'lua')
  )
  table.sort(paths)
  return paths
end

--- How the run is spread over processes, or nil for a run in this one.
--- `--isolate` or `--jobs` asks for processes, and the other takes a default.
--- @param parsed table<string, any>
--- @param entry string  the running `test.lua`, which each worker runs again
--- @return test.executor.Options?
local function isolation(parsed, entry)
  local unit, jobs, timeout = parsed['--isolate'], parsed['--jobs'], parsed['--timeout']
  if unit and unit ~= 'file' and unit ~= 'case' then
    error(('--isolate takes file or case, not %q'):format(unit), 0)
  end
  if jobs and (jobs < 1 or jobs % 1 ~= 0) then
    error(('--jobs takes a whole number above 0, not %s'):format(jobs), 0)
  end
  if timeout and (timeout <= 0 or timeout % 1 ~= 0) then
    error(('--timeout takes a whole number of ms above 0, not %s'):format(timeout), 0)
  end
  if not unit and not jobs then
    -- Lua cannot stop a running function, so only a parent process can stop
    -- a case that hangs.
    if timeout then error('--timeout needs --isolate or --jobs', 0) end
    return nil
  end
  return {
    per_case = unit == 'case',
    jobs = jobs or vim.uv.available_parallelism(),
    timeout_ms = timeout,
    entry = vim.fs.normalize(vim.fn.fnamemodify(entry, ':p')),
  }
end

--- Run the command line `argv` and return the process's exit status. `argv[0]`
--- is the running `test.lua`, which an isolated run starts again in each worker.
--- @param argv string[]
--- @return integer
function M.main(argv)
  running = true
  -- Specs require the plugin's own modules, which live under `lua/` in the
  -- directory the run starts from.
  package.path = 'lua/?.lua;lua/?/init.lua;' .. package.path

  --- @param err any
  --- @return integer
  local function usage_error(err)
    io.stderr:write('test: ', tostring(err), '\n\n', USAGE)
    return 2
  end
  local ok, parsed = pcall(args.parse, ARGS_SPEC, argv)
  if not ok then return usage_error(parsed) end
  if parsed['--worker'] then return require('test.executor').work(parsed['--worker']) end
  local isolate_ok, isolated = pcall(isolation, parsed, assert(argv[0]))
  if not isolate_ok then return usage_error(isolated) end
  if parsed['--help'] then
    io.stdout:write(USAGE)
    return 0
  end

  local includes = #parsed._ > 0 and parsed._ or { 'spec' }
  local found_ok, paths = pcall(
    function() return find_specs(includes, vim.tbl_map(compile, parsed['--exclude'] or {})) end
  )
  if not found_ok then
    io.stderr:write('test: ', tostring(paths), '\n')
    return 2
  end
  if #paths == 0 then
    io.stderr:write('test: no spec files matched ', table.concat(includes, ' '), '\n')
    return 1
  end

  -- Escape codes help a person at a terminal and clutter a pipe or a log, so
  -- they are on only for a terminal, unless --color asks for them anyway.
  local paint = require 'test.color'(parsed['--color'] or vim.uv.guess_handle(1) == 'tty')

  if parsed['--coverage'] then coverage.start() end
  local suite = require 'test.suite'
  local executor = require 'test.executor'
  local run = suite.Suite.collect(paths)
  local filter = parsed['--filter']
  if filter then
    run = run:select(function(case) return suite.full_name(case):find(filter, 1, true) ~= nil end)
  end
  local execute = isolated and executor.spawner(isolated) or executor.in_process
  local report = require('test.report').new(paint)
  execute(run, function(event) report:event(event) end)
  report:summary()
  if parsed['--coverage'] then coverage.report(coverage.stop(), coverage_paths(), paint) end
  return report.counts.failed > 0 and 1 or 0
end

return M
