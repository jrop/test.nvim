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
  local cmd = { vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-l', INIT }
  vim.list_extend(cmd, argv or {})
  local result = vim.system(cmd, { cwd = dir, text = true }):wait()
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
end)
it('checks the log', function() assert.deep_equal(_G.log, { 'after_all' }) end)
]],
    }
    local code, out = cli(dir)
    assert.equal(code, 1)
    assert.contains(out, '  ✗ db reads\n  ✗ db writes\n')
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
    local result = vim
      .system({ vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-l', 'spec/alone_spec.lua' }, {
        cwd = dir,
        text = true,
        env = { LUA_PATH = ('%s/?.lua;%s/?/init.lua;;'):format(LUA_DIR, LUA_DIR) },
      })
      :wait()
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
