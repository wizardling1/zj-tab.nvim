
local ok, m = pcall(require, "zj-tab")
if ok then
  m.setup()
  vim.api.nvim_create_user_command("ZJTabRefresh", function() m.refresh() end, { })
end

