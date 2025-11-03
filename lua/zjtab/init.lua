
-- --- Utilities

local function notify(msg, level)
  vim.notify("zj-tab.nvim: " .. msg, level, { title = "zj-tab.nvim" })
end

--- --- Class ---

local function class()
  local class_table = {}
  class_table.__index = class_table
  return class_table
end

--- --- Config ---

local DEFAULTS = {
  max_width = 40,
  max_directories = 5,
  show_path_for_file = false,
  show_path_for_directory = false,

  enable_icons = true,
  multi_buffer_icon = "",
  directory_icon = "",
  default_icon = "",

  fallback_original_tab_name = "Tab",
  fallback_buffer_name = "[No Name]",

  debounce_milliseconds = 20,
  enable_debug_logs = false,
}

local Config = class()

function Config:new()
  return setmetatable(vim.deepcopy(DEFAULTS), self)
end

function Config:merge(opts)
  if not opts then return self end
  local merged = vim.tbl_deep_extend("force", {}, self, opts)
  for k, v in pairs(merged) do self[k] = v end
  return self
end

--- --- Zellij client ---

local Zellij = class()

function Zellij:new()
  return setmetatable({}, self)
end

function Zellij:available()
  return (vim.env.ZELLIJ ~= nil) and (vim.fn.executable("zellij") == 1)
end

function Zellij:action_wait(arguments)
  return vim.fn.system(vim.list_extend({ "zellij", "action" }, arguments))
end

function Zellij:action_async(arguments, options)
  options = options or {}
  options.detach = true
  return vim.fn.jobstart(vim.list_extend({ "zellij", "action" }, arguments), options)
end

function Zellij:rename_tab_async(name)
  self:action_async({"rename-tab", name})
end

function Zellij:focused_tab_name()
  local layout_dump = self:action_wait({"dump-layout"})--vim.fn.system({ "zellij", "action", "dump-layout" })
  if not layout_dump or layout_dump == "" then return nil end
  for line in layout_dump:gmatch("[^\r\n]+") do
    if line:find("tab") and line:find("focus%s*=%s*true") then
      return line:match('name%s*=%s*"([^"]+)"')
    end
  end
  return nil
end

-- --- Devicons ---

local Devicons = class()

function Devicons:new()
  local ok, api = pcall(require, "nvim-web-devicons")
  return setmetatable({ api = ok and api or nil }, self)
end

function Devicons:available()
  return self.api ~= nil
end

function Devicons:get_icon(buffer_name)
  if not self.api then return nil end
  local tail = vim.fn.fnamemodify(buffer_name, ":t")
  local extension = vim.fn.fnamemodify(buffer_name, ":e")
  local icon = self.api.get_icon(tail, extension, { default = true })
  return icon
end
-- --- NvimTree ---

local NvimTree = class()

function NvimTree:new()
  local ok, api = pcall(require, "nvim-tree.api")
  return setmetatable({ api = ok and api or nil }, self)
end

function NvimTree:available()
  return self.api ~= nil and self.api.tree.is_visible()
end

function NvimTree:absolute_path()
  if not self:available() then return end
  local node = self.api.tree.get_node_under_cursor()
  return node and node.absolute_path or nil
end

function NvimTree:absolute_path_tail()
  local absolute_path = self:absolute_path()
  if absolute_path then return vim.fn.fnamemodify(absolute_path, ":t") end
  return nil
end

-- --- TabRenamer ---

local TabRenamer = class()

function TabRenamer:new(config, zellij, devicons, nvimtree)
  if config.enable_icons and not devicons:available() then
    notify(
      "Could not find nvim-web-devicons plugin. Falling back to the default icon.",
      vim.log.levels.WARN
    )
  end
  return setmetatable({
    config = config,
    zellij = zellij,
    devicons = devicons,
    nvimtree = nvimtree,
    pending = false,
    last_name = nil,
    original_name = nil,
  }, self)
end

local function truncate(str, max_width)
  local width = vim.fn.strdisplaywidth(str)
  if width <= max_width then
    return str
  else
    return vim.fn.strcharpart(str, 0, max_width - 1) .. "…"
  end
end

local function replace_home_with_tilde(path)
  if not path or path == "" then return "" end
  local home = vim.fn.expand("~")
  return path:gsub("^" .. vim.pesc(home), "~")
end

local function truncate_directories(path, max_directories)
  if not path or path == "" then return "" end

  local parts = {}
  for dir in path:gmatch("[^/]+") do
    table.insert(parts, dir)
  end

  local total = #parts
  local truncated = false

  if total > max_directories then
    local new_parts = {}
    for i = total - max_directories + 1, total do
      table.insert(new_parts, parts[i])
    end
    parts = new_parts
    truncated = true
  end

  local truncated_path = table.concat(parts, "/")

  if path:sub(1, 1) == "/" and truncated_path:sub(1, 1) ~= "~" then
    truncated_path = "/" .. truncated_path
  end

  if truncated then
    truncated_path = "…/" .. truncated_path
  end

  return truncated_path
end

local function prefix_icon(icon , str)
  if not icon or icon == "" then return str end
  return str == "" and icon or icon .. " " .. str
end

local function buffer_count() return #vim.fn.getbufinfo({ buflisted = 1 }) end
local function current_buffer_type() return vim.bo.filetype end
local function current_buffer_name() return vim.fn.expand("%:t") end
local function current_buffer_absolute_path() return vim.fn.expand("%:p") end

local function netrw_current_directory()
  if current_buffer_type() == 'netrw' then
    return vim.b.netrw_curdir
  else
    return nil
  end
end

function TabRenamer:compute_name_from_buffer()
  local buffer_filetype = current_buffer_type()
  local fallback_name = self.config.fallback_buffer_name
  local fallback_icon = self.config.default_icon
  local name, icon


  if buffer_filetype == "netrw" then
    name = netrw_current_directory()
    if name and not self.config.show_path_for_directory then
      name = vim.fn.fnamemodify(name, ":t")
    end
    icon = self.config.directory_icon
  elseif buffer_filetype == "NvimTree" then
    if self.config.show_path_for_directory then
      name = self.nvimtree:absolute_path()
    else
      name = self.nvimtree:absolute_path_tail()
    end
    icon = self.config.directory_icon
  else
    if self.config.show_path_for_file then
      name = current_buffer_absolute_path()
    else
      name = current_buffer_name()
    end
    if self.config.enable_icons then
      icon = self.devicons:get_icon(name)
      fallback_icon = self.config.default_icon
    else
      icon = self.config.default_icon
    end
  end

  if icon == self.config.directory_icon or self.config.show_path_for_file then
    name = truncate_directories(replace_home_with_tilde(name), self.config.max_directories)
  end

  if name == "" then name = nil end

  local tab_name = name or fallback_name
  local tab_icon = icon or fallback_icon
  local multi_icon = self.config.multi_buffer_icon
  local max_width = self.config.max_width

  local title = tab_name

  if self.config.enable_icons then
    title = prefix_icon(tab_icon, title)
    if buffer_count() > 1 then title = prefix_icon(multi_icon, title) end
  end
  title = truncate(title, max_width)

  return title
end

function TabRenamer:rename_now()
  local name = self:compute_name_from_buffer()
  if name ~= self.last_name then
    self.last_name = name
    self.zellij:rename_tab_async(name)
  end
end

function TabRenamer:schedule_rename(force_rename)
  if self.pending then return end
  self.pending = true
  if force_rename then self.last_name = nil end
  vim.defer_fn(function()
    self:rename_now()
    self.pending = false
  end, self.config.debounce_milliseconds)
end

function TabRenamer:capture_original_name()
  local name = self.zellij:focused_tab_name()
  if name == nil then
    local fallback_name = self.config.fallback_original_tab_name
    notify(
      "Could not retrieve original pre-neovim tab name. Defaulting to `" .. fallback_name .. "`.",
      vim.log.levels.INFO
    )
    name = fallback_name
  end
  self.original_name = name
end

function TabRenamer:restore_original_name()
  if self.original_name ~= nil then
    self.zellij:rename_tab_async(self.original_name)
  end
end

-- --- Autocommands ---

local AutoCommands = class()

function AutoCommands:new()
  return setmetatable({ group = nil}, self)
end

function AutoCommands:create_group(name)
  self.group = vim.api.nvim_create_augroup(name, { clear = true })
  return self.group
end

function AutoCommands:create_command(events, callback, description)
  vim.api.nvim_create_autocmd(events, {
    group = self.group,
    callback = callback,
    desc = description,
  })
end

function AutoCommands:clear()
  if self.group then pcall(vim.api.nvim_del_augroup_by_id, self.group) end
  self.group = nil
end

-- --- Module ---

local M = { enabled = false }

local config = Config:new()
local zellij = Zellij:new()
local devicons = Devicons:new()
local nvimtree = NvimTree:new()
local renamer = TabRenamer:new(config, zellij, devicons, nvimtree)
local autocommands = AutoCommands:new()

local function debug_log(message)
  if config.enable_debug_logs then notify(message, vim.log.levels.DEBUG) end
end

function M.setup(opts)
  config:merge(opts)

  if not zellij:available() then
    debug_log("Not in Zellij; plugin disabled")
    return
  end

  renamer:capture_original_name()

  debug_log("Captured original name: " .. tostring(renamer.original_name))

  autocommands:create_group("ZJTab")
  autocommands:create_command(
    {
      "BufEnter",
      "BufFilePost",
      "BufWritePost",
      "TabEnter",
      "TermOpen",
    },
    function() renamer:schedule_rename(false) end,
    "zj-tab.nvim: Rename Zellij tab to Neovim buffer name"
  )
  autocommands:create_command(
    "FocusGained",
    function() renamer:schedule_rename(true) end,
    "zj-tab.nvim: Refresh Zellij tab name on focus gained"
  )
  autocommands:create_command(
    "VimLeavePre",
    function() M.teardown() end,
    "zj-tab.nvim: Deleted autogroup and restoring original tab name"
  )

  renamer:schedule_rename(true)
  M.enabled = true
end

function M.refresh() renamer:schedule_rename(true) end

function M.teardown()
  renamer:restore_original_name()
  autocommands:clear()
  M.enabled = false
end

function M.toggle()
  if M.enabled then M.teardown()
  else M.setup()
  end
end

return M
