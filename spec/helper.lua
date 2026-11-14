-- Under `busted --coverage`, luacov's tick interval flushes every 100 hits, but
-- the parent test process exits through Neovim rather than Lua's os.exit, so
-- the final partial batch would be lost without this save.
if package.loaded['luacov.runner'] then
  ---@type { save_stats: fun() }
  local runner = package.loaded['luacov.runner']
  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function() runner.save_stats() end,
  })
end
