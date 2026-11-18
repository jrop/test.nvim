-- The runner is checked from outside: each case writes a small spec project to
-- a temporary directory and runs the CLI on it in a separate `nvim -l`, the
-- way a user would. The project's specs run inside that process, so they
-- cannot disturb the run executing these cases.
local Test = require 'test'
local describe, it, after_each = Test.describe, Test.it, Test.after_each
local assert = Test.assert

local INIT = vim.fs.normalize(vim.fn.fnamemodify('lua/test/init.lua', ':p'))
local LUA_DIR = vim.fs.dirname(vim.fs.dirname(INIT))

-- The header every project spec starts with.
local HEADER = [[
local Test = require 'test'
local describe, it, pending = Test.describe, Test.it, Test.pending
local before_all, after_all = Test.before_all, Test.after_all
local before_each, after_each = Test.before_each, Test.after_each
local assert = Test.assert
]]

local projects = {} --- @type string[]

--- Write `files` (relative path to contents) into a new temporary directory.
--- @param files table<string, string>
--- @return string dir
local function project(files)
  local dir = vim.fn.tempname()
  for rel, contents in pairs(files) do
    local path = vim.fs.joinpath(dir, rel)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile(vim.split(contents, '\n'), path)
  end
  projects[#projects + 1] = dir
  return dir
end

--- @param dir string
--- @param argv? string[]
--- @return integer code, string output  stdout followed by stderr
local function cli(dir, argv)
  -- `Nvim.script`, rather than `vim.system`, lets a coverage run of this
  -- repository count the lines the CLI runs in that process.
  local result = Test.Nvim.script(INIT, argv, { cwd = dir })
  return result.code, (result.stdout or '') .. (result.stderr or '')
end

after_each(function()
  for _, dir in ipairs(projects) do
    vim.fn.delete(dir, 'rf')
  end
  projects = {}
end)

describe('the runner', function()
  it('reports passing, failing, and pending cases, and exits 1 on a failure', function()
    local dir = project {
      ['spec/math_spec.lua'] = HEADER .. [[
describe('math', function()
  it('adds', function() assert.equal(1 + 1, 2) end)
  it('fails', function() assert.deep_equal({ 'a' }, { 'b' }) end)
  pending('later')
end)
]],
    }
    local code, out = cli(dir)
    assert.equal(code, 1)
    assert.contains(out, '  ✓ math adds\n')
    assert.contains(out, '  ✗ math fails\n')
    assert.contains(out, '  - math later (pending)\n')
    assert.contains(out, '- "a"\n+ "b"')
    assert.contains(out, '1 passed, 1 failed, 1 pending')
  end)

  it('prints the time of a case slower than 75 ms beside its name', function()
    local dir = project {
      ['spec/time_spec.lua'] = HEADER .. [[
it('fast', function() end)
it('slow', function() vim.uv.sleep(100) end)
it('slow and failing', function()
  vim.uv.sleep(100)
  error 'late'
end)
]],
    }
    local _, out = cli(dir)
    assert.contains(out, '  ✓ fast\n')
    assert.matches(out, '  ✓ slow %(%d+ms%)\n')
    assert.matches(out, '  ✗ slow and failing %(%d+ms%)\n')
  end)

  it("paints a slow case's time dim", function()
    local dir = project {
      ['spec/time_spec.lua'] = HEADER .. "it('slow', function() vim.uv.sleep(100) end)\n",
    }
    local _, out = cli(dir, { '--color' })
    assert.matches(out, ' slow \27%[2m%(%d+ms%)\27%[0m\n')
  end)

  it('exits 0 when every case passes', function()
    local dir = project {
      ['spec/ok_spec.lua'] = HEADER .. "it('passes', function() end)\n",
    }
    local code, out = cli(dir)
    assert.equal(code, 0, out)
  end)

  it('runs before_each outer to inner and after_each inner to outer', function()
    local dir = project {
      ['spec/hooks_spec.lua'] = HEADER .. [[
_G.log = {}
describe('outer', function()
  before_each(function() table.insert(_G.log, 'before outer') end)
  after_each(function() table.insert(_G.log, 'after outer') end)
  describe('inner', function()
    before_each(function() table.insert(_G.log, 'before inner') end)
    after_each(function() table.insert(_G.log, 'after inner') end)
    it('fails', function() error 'boom' end)
  end)
  it('saw the hooks', function()
    assert.deep_equal(_G.log, {
      'before outer', 'before inner', 'after inner', 'after outer', 'before outer',
    })
  end)
end)
]],
    }
    local _, out = cli(dir)
    assert.contains(out, '  ✗ outer inner fails\n')
    assert.contains(out, '  ✓ outer saw the hooks\n')
  end)

  it('skips a case whose before_each fails, and still runs its after_each', function()
    local dir = project {
      ['spec/hooks_spec.lua'] = HEADER .. [[
_G.log = {}
describe('setup', function()
  before_each(function() error 'setup broke' end)
  after_each(function() table.insert(_G.log, 'after') end)
  it('never runs', function() table.insert(_G.log, 'case') end)
end)
it('checks the log', function() assert.deep_equal(_G.log, { 'after' }) end)
]],
    }
    local _, out = cli(dir)
    assert.contains(out, '  ✗ setup never runs\n')
    assert.contains(out, 'setup broke')
    assert.contains(out, '  ✓ checks the log\n')
  end)

  it('runs before_all and after_all once per scope, around its nested cases', function()
    local dir = project {
      ['spec/all_spec.lua'] = HEADER .. [[
_G.log = {}
local function log(entry) return function() table.insert(_G.log, entry) end end
describe('outer', function()
  before_all(log 'before_all outer')
  after_all(log 'after_all outer')
  before_each(log 'before_each outer')
  it('one', log 'one')
  describe('inner', function()
    before_all(log 'before_all inner')
    after_all(log 'after_all inner')
    it('two', log 'two')
    it('three', log 'three')
  end)
end)
it('saw the hooks', function()
  assert.deep_equal(_G.log, {
    'before_all outer',
    'before_each outer', 'one',
    'before_all inner',
    'before_each outer', 'two',
    'before_each outer', 'three',
    'after_all inner',
    'after_all outer',
  })
end)
]],
    }
    local code, out = cli(dir)
    assert.equal(code, 0, out)
  end)

  it('fails every case in a scope whose before_all fails, and still runs after_all', function()
    local dir = project {
      ['spec/all_spec.lua'] = HEADER .. [[
_G.log = {}
describe('db', function()
  before_all(function() error 'no connection' end)
  after_all(function() table.insert(_G.log, 'after_all') end)
  it('reads', function() table.insert(_G.log, 'reads') end)
  it('writes', function() table.insert(_G.log, 'writes') end)
  pending('migrates')
end)
it('checks the log', function() assert.deep_equal(_G.log, { 'after_all' }) end)
]],
    }
    local code, out = cli(dir)
    assert.equal(code, 1)
    assert.contains(out, '  ✗ db reads\n  ✗ db writes\n')
    -- A pending case never runs, so the failed setup does not fail it.
    assert.contains(out, '  - db migrates (pending)\n')
    assert.contains(out, 'before_all in db failed:')
    assert.contains(out, 'no connection')
    assert.contains(out, '  ✓ checks the log\n')
  end)

  it('reports a failing after_all under its scope', function()
    local dir = project {
      ['spec/all_spec.lua'] = HEADER .. [[
describe('db', function()
  after_all(function() error 'cleanup broke' end)
  it('reads', function() end)
end)
]],
    }
    local code, out = cli(dir)
    assert.equal(code, 1)
    assert.contains(out, '  ✓ db reads\n  ✗ db (after_all)\n')
    assert.contains(out, 'cleanup broke')
  end)

  it('skips the all-hooks of a scope that --filter leaves empty', function()
    local dir = project {
      ['spec/all_spec.lua'] = HEADER .. [[
describe('skipped', function()
  before_all(function() error 'must not run' end)
  it('other', function() end)
end)
it('chosen', function() end)
]],
    }
    local code, out = cli(dir, { '--filter', 'chosen' })
    assert.equal(code, 0, out)
    assert.contains(out, '1 passed, 0 failed, 0 pending')
  end)

  it('reports a file that does not load, and runs the other files', function()
    local dir = project {
      ['spec/broken_spec.lua'] = 'this is not lua (',
      ['spec/ok_spec.lua'] = HEADER .. "it('still runs', function() end)\n",
    }
    local code, out = cli(dir)
    assert.equal(code, 1)
    assert.contains(out, 'spec/broken_spec.lua\n  ✗ (the file did not load)')
    assert.contains(out, '  ✓ still runs\n')
  end)

  it('reports an error raised while a describe is collected', function()
    local dir = project {
      ['spec/collect_spec.lua'] = HEADER .. [[
describe('broken', function() error 'collect broke' end)
]],
    }
    local code, out = cli(dir)
    assert.equal(code, 1)
    assert.contains(out, 'collect broke')
  end)

  it('drops the modules a file loaded before the next file runs', function()
    local spec = HEADER
      .. [[
it('counts once', function()
  local counter = require 'counter'
  counter.n = counter.n + 1
  assert.equal(counter.n, 1)
end)
]]
    local dir = project {
      ['lua/counter.lua'] = 'return { n = 0 }',
      ['spec/a_spec.lua'] = spec,
      ['spec/b_spec.lua'] = spec,
    }
    local code, out = cli(dir)
    assert.equal(code, 0, out)
  end)

  it("shares a module between a file's top level and its cases", function()
    local spec = HEADER
      .. [[
local counter = require 'counter'
it('sees the same instance', function() assert.equal(require 'counter', counter) end)
]]
    local dir = project {
      ['lua/counter.lua'] = 'return {}',
      ['spec/a_spec.lua'] = spec,
      ['spec/b_spec.lua'] = spec,
    }
    for _, argv in ipairs { {}, { '--isolate', 'file' } } do
      local code, out = cli(dir, argv)
      assert.equal(code, 0, out)
    end
  end)

  it('rejects it without a function', function()
    local dir = project {
      ['spec/bad_spec.lua'] = HEADER .. "it('has no body')\n",
    }
    local code, out = cli(dir)
    assert.equal(code, 1)
    assert.contains(out, 'needs a function; use pending')
  end)

  it('explains a describe called outside a run', function()
    local dir = project {
      ['spec/alone_spec.lua'] = HEADER .. "describe('alone', function() end)\n",
    }
    local result = Test.Nvim.script('spec/alone_spec.lua', {}, {
      cwd = dir,
      env = { LUA_PATH = ('%s/?.lua;%s/?/init.lua;;'):format(LUA_DIR, LUA_DIR) },
    })
    assert.not_equal(result.code, 0)
    assert.contains(result.stderr or '', 'no spec run is active')
  end)
end)

describe('the command line', function()
  local function two_files()
    return project {
      ['spec/a_spec.lua'] = HEADER
        .. "it('alpha one', function() end)\nit('beta', function() end)\n",
      ['spec/sub/b_spec.lua'] = HEADER .. "it('alpha two', function() end)\n",
      ['spec/helper.lua'] = 'error "not a spec"',
    }
  end

  it('runs only the cases whose full name contains --filter', function()
    local code, out = cli(two_files(), { '--filter', 'alpha' })
    assert.equal(code, 0, out)
    assert.contains(out, '2 passed, 0 failed, 0 pending')
  end)

  it('includes every *_spec.lua under a directory, and nothing else', function()
    local code, out = cli(two_files(), { 'spec' })
    assert.equal(code, 0, out)
    assert.contains(out, '3 passed')
  end)

  it('includes a single file', function()
    local _, out = cli(two_files(), { 'spec/sub/b_spec.lua' })
    assert.contains(out, '1 passed')
  end)

  it('includes the files a glob matches', function()
    local _, out = cli(two_files(), { 'spec/*_spec.lua' })
    assert.contains(out, '2 passed')
  end)

  it('skips the files --exclude matches', function()
    local _, out = cli(two_files(), { 'spec', '--exclude', 'spec/sub/**' })
    assert.contains(out, '2 passed')
  end)

  it('exits 1 when nothing matches', function()
    local code, out = cli(two_files(), { 'nowhere/*_spec.lua' })
    assert.equal(code, 1)
    assert.contains(out, 'no spec files matched')
  end)

  it('exits 2 on a glob that does not compile', function()
    local code, out = cli(two_files(), { 'spec/[' })
    assert.equal(code, 2)
    assert.contains(out, 'test: invalid glob "spec/["')
  end)

  it('exits 2 on an unknown option', function()
    local code, out = cli(two_files(), { '--bogus' })
    assert.equal(code, 2)
    assert.contains(out, 'unknown or unexpected option: --bogus')
  end)

  it('prints no coverage report without --coverage', function()
    local _, out = cli(two_files())
    assert.equal(out:find('Coverage', 1, true), nil)
  end)

  it('reports coverage of lua/, counting lines run in a child, vendor/ excluded', function()
    local dir = project {
      ['lua/mod/init.lua'] = [[
local M = {}
function M.host() return 1 end
function M.unused()
  return 2
end
function M.child()
  return 3
end
return M
]],
      ['lua/mod/vendor/dep.lua'] = 'return {}',
      ['spec/mod_spec.lua'] = HEADER .. [[
it('uses the module in the host and in a child', function()
  assert.equal(require('mod').host(), 1)
  local nv = Test.Nvim.start()
  assert.equal(nv:run(function() return require('mod').child() end), 3)
  nv:stop()
end)
]],
    }
    local code, out = cli(dir, { '--coverage' })
    assert.equal(code, 0, out)
    assert.contains(out, '\nCoverage\n')
    assert.contains(out, 'lua/mod/init.lua   88.9%  8/9  missed: 4\n')
    assert.equal(out:find('vendor', 1, true), nil, out)
  end)

  it('counts lines a script run by Nvim.script reaches, even through os.exit', function()
    local dir = project {
      ['lua/tool.lua'] = [[
local function unused()
  return 1
end
if arg[1] == 'fail' then
  io.stderr:write 'failing\n'
  os.exit(1)
end
io.stdout:write 'ok\n'
]],
      ['spec/tool_spec.lua'] = HEADER .. [[
it('runs the script to completion and to a failure', function()
  assert.equal(Test.Nvim.script('lua/tool.lua').code, 0)
  assert.equal(Test.Nvim.script('lua/tool.lua', { 'fail' }).code, 1)
end)
]],
    }
    local code, out = cli(dir, { '--coverage' })
    assert.equal(code, 0, out)
    -- Line 8 runs only on the normal exit, and line 6 only on the os.exit path.
    assert.contains(out, 'lua/tool.lua   83.3%  5/6  missed: 2\n')
  end)

  it('joins consecutive missed lines into one range', function()
    local dir = project {
      ['lua/unused.lua'] = [[
local M = {}
function M.unused(t)
  t.a = 1
  t.b = 2
  t.c = 3
end
return M
]],
      ['spec/unused_spec.lua'] = HEADER .. "it('loads it', function() require 'unused' end)\n",
    }
    local code, out = cli(dir, { '--coverage' })
    assert.equal(code, 0, out)
    assert.contains(out, 'missed: 3-5\n')
  end)

  it('leaves out the lines that luacov markers disable', function()
    local dir = project {
      ['lua/marked.lua'] = [[
-- Prose that mentions -- luacov: disable is not a marker.
local M = {}
-- luacov: disable
function M.disabled()
  return 1
end
-- luacov: enable
function M.counted()
  return 2
end
-- luacov: disable
function M.disabled_to_the_end()
  return 3
end
return M
]],
      ['spec/marked_spec.lua'] = HEADER .. "it('loads it', function() require 'marked' end)\n",
    }
    local code, out = cli(dir, { '--coverage' })
    assert.equal(code, 0, out)
    -- Lines 2 and 8-10 are counted; line 9 is the only one that never ran.
    assert.contains(out, 'lua/marked.lua   75.0%  3/4  missed: 9\n')
  end)

  it('never leaves the closing end of a function that ends in error() missed', function()
    local dir = project {
      ['lua/fail.lua'] = [[
local M = {}
function M.fail()
  error 'always'
end
return M
]],
      ['spec/fail_spec.lua'] = HEADER .. [[
it('calls it', function() assert.ok(not pcall(require('fail').fail)) end)
]],
    }
    local code, out = cli(dir, { '--coverage' })
    assert.equal(code, 0, out)
    -- The `end` never runs its return, but it also holds the instruction that
    -- creates the function, so the line runs when the definition does.
    assert.contains(out, 'lua/fail.lua  100.0%  5/5\n')
  end)

  it('leaves type stubs, i.e., files that open with ---@meta, out of coverage', function()
    local dir = project {
      ['lua/mod.lua'] = 'return {}',
      ['lua/mod.types.lua'] = '---@meta\n---@class mod.Thing\n---@field name string\n',
      ['spec/mod_spec.lua'] = HEADER .. "it('loads it', function() require 'mod' end)\n",
    }
    local code, out = cli(dir, { '--coverage' })
    assert.equal(code, 0, out)
    assert.contains(out, 'lua/mod.lua  100.0%')
    assert.equal(out:find('mod.types.lua', 1, true), nil, out)
  end)

  it('reports a source file that does not load instead of skipping it', function()
    local dir = project {
      ['lua/broken.lua'] = 'this is not lua (',
      ['spec/ok_spec.lua'] = HEADER .. "it('passes', function() end)\n",
    }
    local _, out = cli(dir, { '--coverage' })
    assert.matches(out, 'lua/broken%.lua +%- +0/0  did not load: ')
  end)

  it('prints plain text when stdout is not a terminal', function()
    local _, out = cli(two_files())
    assert.equal(out:find('\27[', 1, true), nil, out)
  end)

  it('colors the output with --color', function()
    local dir = project {
      ['spec/color_spec.lua'] = HEADER .. [[
it('passes', function() end)
it('fails', function() assert.deep_equal({ 'a' }, { 'b' }) end)
pending('later')
]],
    }
    local _, out = cli(dir, { '--color' })
    assert.contains(out, '\27[32m✓\27[0m passes')
    assert.contains(out, '\27[31m✗\27[0m fails')
    assert.contains(out, '\27[33m- later (pending)\27[0m')
    assert.contains(out, '\27[31m- "a"\27[0m\n\27[32m+ "b"\27[0m')
    assert.contains(out, '\27[31m1 failed\27[0m')
  end)

  it('prints usage for --help', function()
    local code, out = cli(two_files(), { '--help' })
    assert.equal(code, 0)
    assert.contains(out, 'Usage: nvim -l <test.lua>')
  end)
end)

describe('isolation', function()
  -- A report's lines without the times that slow cases print, so two runs of
  -- the same specs compare equal.
  local function untimed(out) return (out:gsub(' %(%d+ms%)', ''):gsub(' in [%d.]+s\n', '\n')) end

  it('reports the same as a run in one process, for each unit', function()
    local dir = project {
      ['spec/a_spec.lua'] = HEADER .. [[
describe('math', function()
  it('adds', function() assert.equal(1 + 1, 2) end)
  it('fails', function() assert.deep_equal({ 'a' }, { 'b' }) end)
  pending('later')
end)
describe('db', function()
  after_all(function() error 'cleanup broke' end)
  it('reads', function() end)
end)
describe('setup', function()
  before_all(function() error 'no connection' end)
  it('writes', function() end)
end)
]],
      ['spec/b_spec.lua'] = HEADER .. "it('passes', function() end)\n",
      ['spec/broken_spec.lua'] = 'this is not lua (',
    }
    local code, serial = cli(dir)
    assert.equal(code, 1)
    for _, argv in ipairs { { '--isolate', 'file' }, { '--isolate', 'case' }, { '-j', '1' } } do
      local isolated_code, isolated = cli(dir, argv)
      assert.equal(isolated_code, 1, table.concat(argv, ' '))
      assert.equal(untimed(isolated), untimed(serial), table.concat(argv, ' '))
    end
  end)

  it('prints the files in order when a later file finishes first', function()
    local dir = project {
      ['spec/a_spec.lua'] = HEADER .. "it('slow', function() vim.uv.sleep(300) end)\n",
      ['spec/b_spec.lua'] = HEADER .. "it('fast', function() end)\n",
    }
    local code, out = cli(dir, { '-j', '2' })
    assert.equal(code, 0, out)
    assert.matches(out, '^spec/a_spec%.lua\n  ✓ slow %(%d+ms%)\nspec/b_spec%.lua\n  ✓ fast\n')
  end)

  it('runs each file, or with --isolate case each case, in a fresh process', function()
    local dir = project {
      ['spec/state_spec.lua'] = HEADER .. [[
it('sets', function() _G.seen = true end)
it('sees nothing', function() assert.is_nil(_G.seen) end)
]],
    }
    local file_code = cli(dir, { '--isolate', 'file' })
    assert.equal(file_code, 1)
    local case_code, case_out = cli(dir, { '--isolate', 'case' })
    assert.equal(case_code, 0, case_out)
  end)

  it('applies --filter in the parent, still listing a file it leaves empty', function()
    local dir = project {
      ['spec/a_spec.lua'] = HEADER .. "it('chosen', function() end)\nit('other', error)\n",
      ['spec/b_spec.lua'] = HEADER .. "it('also other', error)\n",
    }
    local code, out = cli(dir, { '--isolate', 'case', '--filter', 'chosen' })
    assert.equal(code, 0, out)
    assert.contains(out, 'spec/a_spec.lua\n  ✓ chosen\nspec/b_spec.lua\n')
    assert.contains(out, '1 passed, 0 failed, 0 pending')
  end)

  it('fails the case a worker crashes in, with its output, and the cases after it', function()
    local dir = project {
      ['spec/crash_spec.lua'] = HEADER .. [[
it('passes quietly', function() print 'not shown' end)
it('crashes', function()
  io.stdout:write 'about to crash\n'
  require('ffi').cast('int *', 0)[0] = 1
end)
it('never runs', function() end)
]],
    }
    local code, out = cli(dir, { '--isolate', 'file' })
    assert.equal(code, 1)
    assert.contains(out, '  ✓ passes quietly\n  ✗ crashes\n  ✗ never runs\n')
    assert.matches(
      out,
      '✗ crashes\nthe worker was killed by signal %d+\noutput:\n.-about to crash\n'
    )
    assert.matches(out, '✗ never runs\ndid not run: the worker was killed by signal %d+\n')
    assert.equal(out:find('not shown', 1, true), nil, out)
  end)

  it('shows the output of a failing case, and only of that case', function()
    local dir = project {
      ['spec/out_spec.lua'] = HEADER .. [[
it('passes', function() print 'quiet' end)
it('fails', function()
  print 'first'
  io.stdout:write 'second\n'
  error 'boom'
end)
]],
    }
    local _, out = cli(dir, { '--isolate', 'file' })
    -- `print` writes to stderr and `io.write` to stdout; both reach one file,
    -- in the order they ran. `print` writes its newline before the next
    -- message, so the two lines arrive joined.
    -- The output is the bytes as written: it opens with the newline of the
    -- previous case's `print`.
    assert.matches(out, 'boom\n.-output:\n\nfirstsecond\n')
    assert.equal(out:find('quiet', 1, true), nil, out)
  end)

  it('fails a case that exits the worker, instead of passing silently', function()
    local dir = project {
      ['spec/exit_spec.lua'] = HEADER .. [[
it('exits', function() os.exit(0) end)
it('never runs', function() end)
]],
    }
    local code, out = cli(dir, { '--isolate', 'file' })
    assert.equal(code, 1)
    assert.contains(out, '  ✗ exits\n  ✗ never runs\n')
    assert.contains(out, '✗ exits\nthe worker exited with code 0\n')
  end)

  it('kills a worker that reports nothing for --timeout ms', function()
    local dir = project {
      ['spec/hang_spec.lua'] = HEADER .. [[
it('is slow, but within the timeout', function() vim.uv.sleep(100) end)
it('hangs', function() while true do end end)
it('never runs', function() end)
]],
    }
    local code, out = cli(dir, { '--isolate', 'file', '--timeout', '300' })
    assert.equal(code, 1)
    assert.matches(
      out,
      '  ✓ is slow, but within the timeout %(%d+ms%)\n  ✗ hangs\n  ✗ never runs\n'
    )
    assert.contains(out, '✗ hangs\ntimed out: the worker wrote nothing for 300 ms\n')
    assert.contains(
      out,
      '✗ never runs\ndid not run: timed out: the worker wrote nothing for 300 ms'
    )
  end)

  it('kills what a worker started when the worker exits', function()
    local dir = project {
      ['spec/leak_spec.lua'] = HEADER .. [[
it('leaks a process', function()
  local f = assert(io.open('leaked.pid', 'w'))
  f:write(vim.system({ 'sleep', '30' }).pid)
  f:close()
end)
]],
    }
    local code, out = cli(dir, { '--isolate', 'file' })
    assert.equal(code, 0, out)
    local pid = assert(tonumber(vim.fn.readfile(dir .. '/leaked.pid')[1]))
    -- The orphan is reaped soon after it dies; until then it still has a pid.
    local gone = vim.wait(2000, function() return vim.uv.kill(pid, 0) ~= 0 end, 20)
    if not gone then vim.uv.kill(pid, 'sigkill') end
    assert.ok(gone, 'the leaked process outlived its worker')
  end)

  it('kills its workers when it dies on a signal', function()
    local dir = project {
      ['spec/hang_spec.lua'] = HEADER .. [[
it('hangs', function()
  local f = assert(io.open('worker.pid', 'w'))
  f:write(vim.fn.getpid())
  f:close()
  while true do end
end)
]],
    }
    -- `vim.system`, not `Nvim.script`, because the parent must be signaled
    -- while it runs.
    local parent = vim.system({ vim.v.progpath, '-l', INIT, '--isolate', 'file' }, { cwd = dir })
    local pid_file = dir .. '/worker.pid'
    local pid --- @type integer?
    local started = vim.wait(5000, function()
      pid = vim.uv.fs_stat(pid_file) and tonumber(vim.fn.readfile(pid_file)[1] or '') or nil
      return pid ~= nil
    end, 20)
    if not started then parent:kill 'sigkill' end
    assert.ok(started, 'the worker never started')
    parent:kill 'sigterm'
    parent:wait()
    local gone = vim.wait(2000, function() return vim.uv.kill(assert(pid), 0) ~= 0 end, 20)
    if not gone then vim.uv.kill(assert(pid), 'sigkill') end
    assert.ok(gone, 'the worker outlived its parent')
  end)

  it('fails the cases a worker never reached, when it dies outside any case', function()
    local dir = project {
      ['spec/setup_spec.lua'] = HEADER .. [[
describe('db', function()
  before_all(function() require('ffi').cast('int *', 0)[0] = 1 end)
  it('reads', function() end)
  it('writes', function() end)
end)
]],
    }
    local code, out = cli(dir, { '--isolate', 'file' })
    assert.equal(code, 1)
    assert.contains(out, '  ✗ spec/setup_spec.lua\n  ✗ db reads\n  ✗ db writes\n')
    assert.matches(out, '✗ db reads\ndid not run: the worker was killed by signal %d+\n')
  end)

  it('reports a file that fails to collect only in a worker', function()
    local dir = project {
      ['spec/late_spec.lua'] = HEADER .. [[
local again = vim.uv.fs_stat 'collected' ~= nil
assert(io.open('collected', 'w')):close()
if again then error 'broke on the second load' end
it('passes', function() end)
]],
    }
    local code, out = cli(dir, { '--isolate', 'file' })
    assert.equal(code, 1)
    assert.contains(out, 'spec/late_spec.lua\n  ✗ spec/late_spec.lua\n  ✗ passes\n')
    assert.matches(
      out,
      '✗ spec/late_spec%.lua\nthe worker exited with code 1\noutput:\n.-broke on the second load'
    )
    assert.contains(out, '✗ passes\ndid not run: the worker exited with code 1\n')
  end)

  it('counts the lines that workers and their children run, under --coverage', function()
    local dir = project {
      ['lua/mod.lua'] = [[
local M = {}
function M.worker()
  return 1
end
function M.child()
  return 2
end
return M
]],
      ['spec/mod_spec.lua'] = HEADER .. [[
it('uses the module in the worker and in a child', function()
  assert.equal(require('mod').worker(), 1)
  local nv = Test.Nvim.start()
  assert.equal(nv:run(function() return require('mod').child() end), 2)
  nv:stop()
end)
]],
    }
    local code, out = cli(dir, { '--isolate', 'file', '--coverage' })
    assert.equal(code, 0, out)
    -- Line 3 runs only in the worker, and line 6 only in the worker's child.
    assert.contains(out, 'lua/mod.lua  100.0%  8/8\n')
  end)

  it('exits 2 on a bad --isolate, --jobs, or --timeout', function()
    local dir = project { ['spec/a_spec.lua'] = HEADER .. "it('passes', function() end)\n" }
    for argv, message in pairs {
      [{ '--isolate', 'scope' }] = '--isolate takes file or case, not "scope"',
      [{ '-j', '0' }] = '--jobs takes a whole number above 0, not 0',
      [{ '-j', '1.5' }] = '--jobs takes a whole number above 0, not 1.5',
      [{ '-j', '1', '--timeout', '0' }] = '--timeout takes a whole number of ms above 0, not 0',
      [{ '--timeout', '100' }] = '--timeout needs --isolate or --jobs',
    } do
      local code, out = cli(dir, argv)
      assert.equal(code, 2, table.concat(argv, ' '))
      assert.contains(out, message)
    end
  end)
end)
