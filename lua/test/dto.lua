--- The shapes of the data a run produces and passes between processes: the
--- events every executor emits, the job a worker reads, and the lines it
--- writes back. Each schema both validates at runtime and, through guard's
--- generator, produces the LuaCATS class of the same name in `dto.types.lua`,
--- so the checks and the types cannot drift apart. Requires nothing but guard,
--- because the generator loads this file on its own.
local guard = require 'test.vendor.guard'

local M = {}

--- @param kind string
--- @param fields table<string, Guard>
--- @return Guard
local function event(kind, fields)
  return guard.object(
    vim.tbl_extend('error', fields, { kind = guard.literal(kind) }),
    { strict = true }
  )
end

--- A spec file's events start; every event after it, up to the next, is that
--- file's.
M.FileEvent = event('file', { path = guard.string() })
--- The file failed to load or to collect, so none of its cases ran.
M.LoadErrorEvent = event('load_error', { path = guard.string(), message = guard.string() })
--- A case is about to run, with its `before_each` hooks.
M.StartEvent = event('start', { id = guard.integer(), name = guard.string() })
M.PassEvent = event('pass', { id = guard.integer(), name = guard.string(), ms = guard.number() })
--- A case failed, or something that is not a case did, such as an
--- `after_all`, which has no `id`. `ms` is nil for a case that never ran.
--- `output` is what the case printed, when it ran in a worker.
M.FailEvent = event('fail', {
  id = guard.integer():optional(),
  name = guard.string(),
  message = guard.string(),
  ms = guard.number():optional(),
  output = guard.string():optional(),
})
M.PendingEvent = event('pending', { id = guard.integer(), name = guard.string() })

M.Event = guard.one_of(
  M.FileEvent,
  M.LoadErrorEvent,
  M.StartEvent,
  M.PassEvent,
  M.FailEvent,
  M.PendingEvent
)

--- One worker's assignment: which cases of which file to run, by id. The
--- worker writes its lines beside the job file.
M.Job = guard.object({ path = guard.string(), ids = guard.integer():array() }, { strict = true })

--- One line a worker writes: an event, and the worker's output-file position
--- when it happened, so the bytes between two lines' offsets are what was
--- printed between them.
M.WorkerLine = guard.object({ offset = guard.integer(), event = M.Event }, { strict = true })

return M
