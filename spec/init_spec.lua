--- @diagnostic disable: undefined-field

local Test = require 'test'

describe('test', function()
  it('runs a function in a temporary buffer and cleans up', function()
    local bufnr --- @type integer
    local seen, swapfile
    Test.with_buf({ 'hello' }, function()
      bufnr = vim.api.nvim_get_current_buf()
      seen = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      swapfile = vim.bo.swapfile
    end)
    assert.are.same({ 'hello' }, seen)
    assert.is_false(vim.api.nvim_buf_is_loaded(bufnr))
    assert.is_false(swapfile)
  end)

  it('leaves the global swapfile default alone', function()
    local before = vim.go.swapfile
    Test.with_buf({ 'hello' }, function() end)
    assert.are.same(before, vim.go.swapfile)
  end)
end)
