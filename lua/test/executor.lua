--- The executors: the two ways to run a suite, which emit the same events in
--- the same order, so one report consumes either.
---
--- 1. `in_process` runs the cases here. It is the only code that runs cases.
--- 2. `spawner` (`--isolate`) splits the suite into jobs, one per file or one
---    per case, and runs each job in a worker: `nvim -l <test.lua> --worker
---    <dir>`, started with the parent's own flags. A worker runs its job with
---    `in_process` and writes each event as a line.
---
--- A worker reports through two files, so a worker that crashes loses nothing
--- it already wrote:
---
--- 1. `lines`, one flushed JSON line per event.
--- 2. `output`, its stdout and stderr at once, so `print` (stderr, under
---    `nvim -l`) and `io.write` (stdout) keep the order they ran in. Each line
---    records this file's offset, so the parent knows which case printed what.
---
--- A worker that dies early is diagnosed from the same files: the case it
--- started without finishing fails with the reason, and every case it never
--- reported fails with "did not run".
local coverage = require 'test.coverage'
local dto = require 'test.dto'
local guard = require 'test.vendor.guard'
local suite = require 'test.suite'

local M = {}

--------------------------------------------------------------------------------
-- In process
--------------------------------------------------------------------------------

--- Where a run's events go: the report, or a worker's line writer.
--- @alias test.executor.Emit fun(event: test.dto.Event)

--- The scopes from the file's root down to the case's own scope.
--- @param case test.suite.Case
--- @return test.suite.Scope[]
local function scopes_of(case)
  local scopes = {}
  local scope = case.parent --- @type test.suite.Scope?
  while scope do
    table.insert(scopes, 1, scope)
    scope = scope.parent
  end
  return scopes
end

--- Run one case with its `before_each` and `after_each` hooks, and emit its
--- outcome. Before-hooks run from the outermost scope inward, and a failing
--- one skips the rest and the case; after-hooks run from the innermost scope
--- outward, always.
--- @param case test.suite.Case
--- @param path string
--- @param emit test.executor.Emit
local function run_case(case, path, emit)
  local name = suite.full_name(case)
  if not case.fn then return emit { kind = 'pending', id = case.id, name = name } end

  emit { kind = 'start', id = case.id, name = name }
  local started = vim.uv.hrtime()
  local errors = {}
  --- @param fn fun()
  --- @return boolean
  local function attempt(fn)
    local ok, err = suite.protect(fn, path)
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
  if #errors == 0 then return emit { kind = 'pass', id = case.id, name = name, ms = ms } end
  emit { kind = 'fail', id = case.id, name = name, message = table.concat(errors, '\n\n'), ms = ms }
end

--- The cases under `scope`, nested scopes included, whose ids `ids` holds.
--- @param scope test.suite.Scope
--- @param ids table<integer, true>
--- @param out? test.suite.Case[]
--- @return test.suite.Case[]
local function selected_cases(scope, ids, out)
  out = out or {}
  for _, child in ipairs(scope.children) do
    if child.children then
      selected_cases(child --[[@as test.suite.Scope]], ids, out)
    elseif ids[child.id] then
      out[#out + 1] = child --[[@as test.suite.Case]]
    end
  end
  return out
end

--- Run a scope's selected cases between its `before_all` and `after_all`
--- hooks. A scope with nothing selected runs neither hook. A failing
--- `before_all` skips the rest of the scope and fails each selected case with
--- its error; `after_all` still runs, so it can undo a partial setup.
--- @param scope test.suite.Scope
--- @param path string
--- @param ids table<integer, true>
--- @param emit test.executor.Emit
local function run_scope(scope, path, ids, emit)
  local cases = selected_cases(scope, ids)
  if #cases == 0 then return end
  -- A hook failure is reported under the scope's name, or the file's for the
  -- root scope.
  local scope_name = scope.parent and suite.full_name(scope) or path

  local setup_err --- @type string?
  for _, hook in ipairs(scope.before_all) do
    local ok, err = suite.protect(hook, path)
    if not ok then
      setup_err = ('before_all in %s failed:\n%s'):format(scope_name, err)
      break
    end
  end

  if setup_err then
    for _, case in ipairs(cases) do
      local name = suite.full_name(case)
      if case.fn then
        emit { kind = 'fail', id = case.id, name = name, message = setup_err }
      else
        emit { kind = 'pending', id = case.id, name = name }
      end
    end
  else
    for _, child in ipairs(scope.children) do
      if child.children then
        run_scope(child --[[@as test.suite.Scope]], path, ids, emit)
      elseif ids[child.id] then
        run_case(child --[[@as test.suite.Case]], path, emit)
      end
    end
  end

  for _, hook in ipairs(scope.after_all) do
    local ok, err = suite.protect(hook, path)
    if not ok then
      emit {
        kind = 'fail',
        name = scope_name .. ' (after_all)',
        message = err --[[@as string]],
      }
    end
  end
end

--- The executor that runs a suite in this process: each file in order, with
--- its own modules loaded, emitting each event as it happens.
--- @param run test.Suite
--- @param emit test.executor.Emit
function M.in_process(run, emit)
  for _, file in ipairs(run.files) do
    emit { kind = 'file', path = file.path }
    local root = file.root
    if not root then
      emit { kind = 'load_error', path = file.path, message = assert(file.load_error) }
    else
      local ids = {}
      for _, id in ipairs(file.ids) do
        ids[id] = true
      end
      suite.with_modules(file, function() run_scope(root, file.path, ids, emit) end)
    end
  end
end

--------------------------------------------------------------------------------
-- The worker
--------------------------------------------------------------------------------

--- @param path string
--- @return string?
local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read '*a'
  f:close()
  return text
end

--- Run the job in `dir`, and return the worker's exit status. A file that
--- fails to load raises, so the parent reports it like any worker that died
--- outside a case, with the error in its output.
--- @param dir string
--- @return integer
function M.work(dir)
  local job = guard.from_json(dto.Job):parse(assert(read_file(dir .. '/job.json'))) --[[@as test.dto.Job]]
  local collected = suite.Suite.collect { job.path }
  local file = assert(collected.files[1])
  if not file.root then error(file.load_error, 0) end

  local lines = assert(io.open(dir .. '/lines', 'a'))
  local chosen = collected:select(function(case) return vim.tbl_contains(job.ids, case.id) end)
  M.in_process(chosen, function(event)
    -- The parent emits each file's event itself, once per file.
    if event.kind == 'file' then return end
    io.stdout:flush()
    lines:write(vim.json.encode { offset = io.stdout:seek 'cur' or 0, event = event }, '\n')
    lines:flush()
  end)
  return 0
end

--------------------------------------------------------------------------------
-- The spawner
--------------------------------------------------------------------------------

--- @class test.executor.Options
--- @field per_case boolean  one worker per case, rather than per file
--- @field jobs integer  workers running at once
--- @field timeout_ms? integer  how long a worker may go without writing a line
--- @field entry string  the absolute path of the running `test.lua`

--- Some of one file's cases, and the worker running them.
--- @class test.executor.Job
--- @field file test.SuiteFile
--- @field ids integer[]
--- @field dir string  where the worker's `job.json`, `lines`, and `output` go
--- @field events? test.dto.Event[]  set once the job has finished
--- @field pid? integer
--- @field timer? uv.uv_timer_t
--- @field exit? { code: integer, signal: integer }
--- @field kill_reason? string  why the parent killed the worker, when it did

--- The run's jobs, in file order. A file with nothing to run, e.g. one
--- that failed to load, still gets one job, already finished, so that it
--- keeps its place in the order.
--- @param run test.Suite
--- @param per_case boolean
--- @return test.executor.Job[]
local function jobs_of(run, per_case)
  local jobs = {}
  for _, file in ipairs(run.files) do
    local groups = per_case
        and #file.ids > 0
        and vim.tbl_map(function(id) return { id } end, file.ids)
      or { file.ids }
    for _, ids in ipairs(groups) do
      local events = not file.root
          and { { kind = 'load_error', path = file.path, message = assert(file.load_error) } }
        or #ids == 0 and {}
        or nil
      jobs[#jobs + 1] = { file = file, ids = ids, dir = vim.fn.tempname(), events = events }
    end
  end
  return jobs
end

--- Kill the worker and everything it started. The worker leads its own
--- process group, so this reaches a spec's grandchildren too.
--- @param job test.executor.Job
local function kill(job) vim.uv.kill(-assert(job.pid), 'sigkill') end

--- The wall clock, in the unit and epoch of a file's modification time.
--- @return number
local function wall_ms()
  local seconds, microseconds = assert(vim.uv.gettimeofday())
  return seconds * 1000 + microseconds / 1000
end

--- Kill the worker once it has gone `timeout_ms` without writing a line. The
--- timer wakes only when that could have happened, so it never polls. It
--- runs in a libuv callback, where `vim.fn` is unavailable.
--- @param job test.executor.Job
--- @param timeout_ms integer
local function watch(job, timeout_ms)
  local started, timer = wall_ms(), assert(vim.uv.new_timer())
  job.timer = timer
  local function check()
    if job.exit then return end
    local stat = vim.uv.fs_stat(job.dir .. '/lines')
    local written = stat and stat.mtime.sec * 1000 + stat.mtime.nsec / 1e6 or 0
    local left = math.max(started, written) + timeout_ms - wall_ms()
    if left > 0 then return timer:start(math.ceil(left), 0, check) end
    job.kill_reason = ('timed out: the worker wrote nothing for %d ms'):format(timeout_ms)
    kill(job)
  end
  timer:start(timeout_ms, 0, check)
end

--- The flags the parent started with, before `-l`, e.g. `-u NONE`.
--- @return string[]
local function own_flags()
  local flags = {}
  for i = 2, #vim.v.argv do
    if vim.v.argv[i] == '-l' then break end
    flags[#flags + 1] = vim.v.argv[i]
  end
  return flags
end

--- Start the job's worker, the same way the parent was started.
--- @param job test.executor.Job
--- @param opts test.executor.Options
--- @return test.executor.Job
local function start(job, opts)
  vim.fn.mkdir(job.dir, 'p')
  vim.fn.writefile(
    { vim.json.encode { path = job.file.path, ids = job.ids } },
    job.dir .. '/job.json'
  )
  local output = assert(vim.uv.fs_open(job.dir .. '/output', 'w', 420)) -- 0644
  local process, pid --- @type uv.uv_process_t?, integer|string
  process, pid = vim.uv.spawn(vim.v.progpath, {
    -- This run's `--cmd` goes last, after any outer coverage run's in the
    -- parent's flags, so that the worker's own children record into it.
    args = vim.list_extend(
      vim.list_extend(own_flags(), coverage.argv()),
      { '-l', opts.entry, '--worker', job.dir }
    ),
    stdio = { nil, output, output },
    detached = true, -- its own process group, for `kill`
  }, function(code, signal)
    job.exit = { code = code, signal = signal }
    assert(process):close()
  end)
  vim.uv.fs_close(output)
  if not process then error(('test: could not start a worker: %s'):format(pid), 0) end
  job.pid = pid --[[@as integer]]
  if opts.timeout_ms then watch(job, opts.timeout_ms) end
  return job
end

--- @param text string
--- @return string?
local function nonempty(text) return text ~= '' and text or nil end

--- A finished job's events: the worker's, with each failure's output, and,
--- when the worker died early, a failure for the case it was running and for
--- every case it never reported.
--- @param job test.executor.Job
--- @return test.dto.Event[]
local function events_of(job)
  local output = read_file(job.dir .. '/output') or ''
  -- Only complete lines count: a killed worker can leave its last one short.
  -- Only this library writes them, so one that does not parse is a bug.
  local lines = {} --- @type test.dto.WorkerLine[]
  for text in (read_file(job.dir .. '/lines') or ''):gmatch '([^\n]*)\n' do
    lines[#lines + 1] = guard.from_json(dto.WorkerLine):parse(text)
  end

  local events, reported = {}, {} --- @type test.dto.Event[], table<integer, true>
  for i, line in ipairs(lines) do
    local event, previous = line.event, lines[i - 1]
    -- emmylua does not narrow on `kind` through the `test.dto.Event` alias.
    if event.kind == 'fail' then
      local from = previous and previous.offset or 0
      (event --[[@as test.dto.FailEvent]]).output = nonempty(output:sub(from + 1, line.offset))
    end
    if event.kind ~= 'start' and event.id then reported[event.id] = true end
    events[#events + 1] = event
  end

  local exit = assert(job.exit)
  local missing = vim.tbl_filter(function(id) return not reported[id] end, job.ids)
  if not job.kill_reason and exit.code == 0 and exit.signal == 0 and #missing == 0 then
    return events
  end

  -- Exit code 0 lands here too, e.g. from a spec that calls `os.exit(0)`.
  local reason = job.kill_reason
    or exit.signal ~= 0 and ('the worker was killed by signal %d'):format(exit.signal)
    or ('the worker exited with code %d'):format(exit.code)
  -- A worker writes a case's start before running it, so a worker that died
  -- in a case wrote that start last. Without one, e.g. in a `before_all`,
  -- the file takes the failure.
  local last = lines[#lines]
  local running = last and last.event.kind == 'start' and last.event --[[@as test.dto.StartEvent]]
    or nil
  events[#events + 1] = {
    kind = 'fail',
    id = running and running.id or nil,
    name = running and running.name or job.file.path,
    message = reason,
    output = nonempty(output:sub((last and last.offset or 0) + 1)),
  }
  for _, id in ipairs(missing) do
    if not running or id ~= running.id then
      local name = suite.full_name(job.file.cases[id])
      events[#events + 1] =
        { kind = 'fail', id = id, name = name, message = 'did not run: ' .. reason }
    end
  end
  return events
end

--- Release an exited worker: stop its timer, kill what it left running,
--- read its events, and delete its files.
--- @param job test.executor.Job
local function finish(job)
  if job.timer then job.timer:close() end
  kill(job)
  job.events = events_of(job)
  vim.fn.delete(job.dir, 'rf')
end

--- The spawner executor: `M.spawner(opts)(run, emit)` runs a suite's jobs,
--- `opts.jobs` at a time, and emits their events in file order, the same
--- order as the in-process executor.
--- @param opts test.executor.Options
--- @return fun(run: test.Suite, emit: test.executor.Emit)
function M.spawner(opts)
  return function(run, emit)
    local jobs = jobs_of(run, opts.per_case)
    local queue = vim.tbl_filter(function(job) return not job.events end, jobs)
    local running = {} --- @type table<test.executor.Job, true>

    -- Jobs finish in any order, so a job's events wait for every job before
    -- it to finish too.
    local emitted = 0
    local function emit_finished()
      while true do
        local job, previous = jobs[emitted + 1], jobs[emitted]
        if not job or not job.events then return end
        emitted = emitted + 1
        if not previous or previous.file ~= job.file then
          emit { kind = 'file', path = job.file.path }
        end
        for _, event in ipairs(job.events) do
          emit(event)
        end
      end
    end

    -- Workers run in their own process groups, which a terminal's Ctrl-C does
    -- not reach, so the parent kills them when it dies. `nvim -l` runs
    -- VimLeavePre on every deadly signal, including SIGINT.
    local cleanup = vim.api.nvim_create_autocmd('VimLeavePre', {
      callback = function()
        -- A coverage run's own VimLeavePre has turned the line hook off.
        -- luacov: disable
        for job in pairs(running) do
          kill(job)
        end
        -- luacov: enable
      end,
    })

    emit_finished()
    while #queue > 0 or next(running) do
      while vim.tbl_count(running) < opts.jobs and #queue > 0 do
        running[start(table.remove(queue, 1), opts)] = true
      end
      vim.wait(math.huge, function()
        for job in pairs(running) do
          if job.exit then return true end
        end
        return false
      end)
      for job in pairs(running) do
        if job.exit then
          running[job] = nil
          finish(job)
        end
      end
      emit_finished()
    end
    vim.api.nvim_del_autocmd(cleanup)
  end
end

return M
