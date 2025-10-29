
-- add directory name parsing
--  - replace home with ~
--  - add maximum directory depth
--  - add github detection
--  get rid of race conditions

--- --- Class ---

local function class()
  local class_table = {}
  class_table.__index = class_table
  return class_table
end

--- --- Config ---

local DEFAULTS = {
  tab = {
    max_width = 20,
    enable_devicons = true,
  },
  icons = {
    multi_buffer = "",
    directory = "",
    default_icon = "",
  },
  runtime = {
    debounce_milliseconds = 20,
    enable_debug_logs = true,
  },
  fallbacks = {
    restored_tab_name = "Tab",
    buffer_name = "[No Name]",
  }
}

local Config = class()

function Config:new()
  return setmetatable(vim.deepcopy(DEFAULTS), self)
end

function Config:merge(opts)
  if opts then
    local merged = vim.tbl_deep_extend("force", self, opts)
    setmetatable(merged, getmetatable(self))
  end
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

function Zellij:focused_tab_name()
  local layout_dump = vim.fn.system({ "zellij", "action", "dump-layout" })
  if not layout_dump or layout_dump == "" then return nil end
  for line in layout_dump:gmatch("[^\r\n]+") do
    if line:find("tab") and line:find("focus%s*=%s*true") then
      return line:match('name%s*=%s*"([^"]+)"')
    end
  end
  return nil
end

-- --- Devicons ---

local Devicons = {}
Devicons.__index = Devicons

function Devicons:new()
  local ok, api = pcall(require, "nvim-web-devicons")
  return setmetatable({ api = ok and api or nil }, self)
end

function Devicons:available()
  return self.api ~= nil
end

function Devicons:get_icon(bufname)
  if not self.api then return nil end
  local ext = vim.fn.fnamemodify(bufname, ":e")
  local icon = self.api.get_icon(bufname, ext, { default = true })
  return icon
end

-- --- NvimTree ---

-- --- TabRenamer ---
local TabRenamer = class()

function TabRenamer:new(config, zellij, devicons)
  return setmetatable({
    config = config,
    zellij = zellij,
    devicons = devicons,
    pending = false,
    last_name = nil,
    original_name = { known = false, name = nil }
  }, self)
end

local function truncate(string, max_width)
  local width = vim.fn.strdisplaywidth(string)
  if width <= max_width then
    return string
  else
    return vim.fn.strcharpart(string, 0, max_width - 1) .. "…"
  end
end

local function buffer_count()
  return #vim.fn.getbufinfo({ buflisted = 1 })
end

function TabRenamer:compute_name_from_buffer()
  local buffer_filetype = vim.bo.filetype
  local icon, name

  if buffer_filetype == "netrw" then
    icon = self.config.icons.directory
    name = vim.b.netrw_curdir or self.config.fallbacks.buffer_name
  elseif buffer_filetype == "NvimTree" then
    icon = self.config.icons.directory
    name = self.config.fallback.buffername
  else
    name = vim.fn.expand("%:t")
    if name == "" then name = self.config.fallbacks.buffer_name end
    -- pick up here
  end
end

-- --- old state ---

local state = {
  zj_tab = {
    autocommand_group = nil,
  },
  tab = {
    pending = false,
    last_set_tab_name = nil,
    original_tab_name = { known = false, name = config.fallbacks.restored_tab_name },
    rename_tab_function = nil,
  },
  loaded_plugins = {
    devicons = nil,
    nvim_tree_api = nil,
  },
}

-- --- Utilities ---

local function merge_into(destination, source)
  if not source then return destination end
  for key, value in pairs(source) do
    if type(value) == "table" and type(destination[key]) == "table" then
      merge_into(destination[key], value)
    else
      destination[key] = value
    end
  end
  return destination
end

local function notify(message, level)
  vim.notify("zj-tab.nvim: " .. message, level, { title = "zj-tab.nvim" })
end

local function debug_log(message)
  if config.runtime.enable_debug_logs then notify(message, vim.log.levels.DEBUG) end
end

local function get_plugin(plugin_name)
  local ok, plugin = pcall(require, plugin_name)
  if ok then
    return plugin
  else
    return nil
  end
end

-- --- Devicons ---

local function prefix_devicon(text, icon)
  if type(text) ~= "string" then
    debug_log("prefix_devicon: 'text' argument is supposed to be string, is instead " .. type(text))
    return
  elseif text == "" then
    return icon
  else
    return icon .. " " .. text
  end
end

local function prefix_text_if(text, prefix, condition)
  if condition then
    if text == "" then
      return prefix
    else
      return prefix .. " " .. text
    end
  else
    return text
  end
end

-- --- Tab renaming ---


local function get_current_buffer_name()
  local name = vim.fn.expand("%:t")
  if name == "" then name = config.fallbacks.buffer_name end
  return name
end

local function rename_tab_normal()
  local name =
    truncate_string(
      get_current_buffer_name(),
      config.tab.max_tab_name_width
    )

  if name ~= state.tab.last_set_tab_name then
    state.tab.last_set_tab_name = name
    zellij.action({ "rename-tab", name })
  end
end

local function rename_tab_with_devicons(get_icon)
  local buffer_type = vim.bo.filetype

  local buffer_name
  local icon

  -- directory buffers
  if buffer_type == "netrw" then
    icon = config.icons.directory
    buffer_name = vim.b.netrw_curdir
  elseif buffer_type == "NvimTree" then
    icon = config.icons.directory
    local tree_api = state.loaded_plugins.nvim_tree_api
    if tree_api ~= nil and tree_api.tree.is_visible() then
      buffer_name = tree_api.tree.get_node_under_cursor().absolute_path
    else
      buffer_name = config.fallbacks.buffer_name
    end
  -- other buffers
  else
    buffer_name = get_current_buffer_name()
    local extension = vim.fn.fnamemodify(buffer_name, ":e")
    icon = get_icon(buffer_name, extension, { default = true })
  end

  local name =
    truncate_string(
      prefix_text_if(
        prefix_devicon(
          buffer_name,
          icon
        ),
        config.icons.multi_buffer,
        buffer_count() > 1
      ),
      config.tab.max_tab_name_width
    )

  if name ~= state.tab.last_set_tab_name then
    state.tab.last_set_tab_name = name
    zellij.action({ "rename-tab", name })
  end
end

local function build_rename_tab_function(enable_devicons, get_icon)
  if enable_devicons then
    return function() rename_tab_with_devicons(get_icon) end
  else
    return rename_tab_normal
  end
end

local function schedule_rename_tab(force)
  if state.tab.pending then return end
  state.tab.pending = true
  if force then state.tab.last_set_tab_name = nil end
  vim.defer_fn(function()
    if state.tab.rename_tab_function then state.tab.rename_tab_function() end
    state.tab.pending = false
  end, config.runtime.debounce_milliseconds)
end

-- --- Plugin API ---

local module = {}

module.enabled = true
module.config = config

function module.refresh()
  schedule_rename_tab(true)
end

function module.teardown(restore)
  if restore then
    zellij.action({ "rename-tab", state.tab.original_tab_name.name })
  end
  if state.zj_tab.autocommand_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.zj_tab.autocommand_group)
    state.zj_tab.autocommand_group = nil
  end
  state.tab.rename_tab_function = nil
  state.tab.pending = false
  state.tab.last_set_tab_name = nil
  state.tab.original_tab_name = { known = false, name = config.fallbacks.restored_tab_name }
  state.loaded_plugins = {
    devicons = nil,
    nvim_tree_api = nil,
  }
end

function module.toggle()
  if module.enabled then
    module.teardown(true)
    module.enabled = false
  else
    module.setup()
    module.enabled = true
  end
end

function module.setup(options)
  -- delete user commands and autocmd group
  pcall(vim.api.nvim_del_user_command, "ZJTabRefresh")
  pcall(vim.api.nvim_del_user_command, "ZJTabToggle")
  pcall(vim.api.nvim_del_augroup_by_name, "ZJTab")

  -- combine user config with default config
  merge_into(config, options)

  -- if not in zellij, the plugin does nothing
  if not zellij.is_in_zellij() then
    return
  end

  -- get pre-nvim tab name
  local original_tab_name = zellij.get_focused_tab_name()
  if original_tab_name == nil then
    notify(
      "Could not discover original tab name: will restore to fallback name `"
        .. config.fallbacks.restored_tab_name .. "`.",
      vim.log.levels.WARN
    )
    state.tab.original_tab_name.name = config.fallbacks.restored_tab_name
    state.tab.original_tab_name.known = false
  else
    state.tab.original_tab_name.name = original_tab_name
    state.tab.original_tab_name.known = true
  end

  debug_log("module.setup: state.tab.original_tab_name = {"
        .. "name = `" .. state.tab.original_tab_name.name
        .. "`, known = " .. tostring(state.tab.original_tab_name.known) .. "}")

  state.zj_tab.autocommand_group = vim.api.nvim_create_augroup("ZJTab", { clear = true })

  -- get plugins (if they are not found, they are set to nil)
  state.loaded_plugins = {
    devicons = get_plugin("nvim-web-devicons"),
    nvim_tree_api = get_plugin("nvim-tree.api"),
  }

  -- configure rename_tab function to use devicons or not
  if config.tab.enable_devicons then
    if state.loaded_plugins.devicons == nil then
      notify(
        "Could not find nvim-web-devicons plugin. Falling back to the default file icon.",
        vim.log.levels.WARN
      )
      state.tab.rename_tab_function = build_rename_tab_function(
        true,
        function(_, _, _) return config.icons.default_icon end
      )
    else
      state.tab.rename_tab_function = build_rename_tab_function(true, state.loaded_plugins.devicons.get_icon)
    end
  else
    state.tab.rename_tab_function = build_rename_tab_function(false)
  end

  -- rename tab on buffer enter, when file name changes, tab enter, or terminal open
  vim.api.nvim_create_autocmd({
    "BufEnter",
    "BufFilePost",
    "BufWritePost",
    "TabEnter",
    "TermOpen",
  }, {
    group = state.zj_tab.autocommand_group,
    callback = function() schedule_rename_tab(false) end,
    desc = "zj-tab.nvim: update Zellij tab title"
  })

  -- force rename tab on focus gained
  -- (important if other code is modifying zellij tab names in new zellij panes)
  vim.api.nvim_create_autocmd("FocusGained", {
    group = state.zj_tab.autocommand_group,
    callback = function() schedule_rename_tab(true) end,
    desc = "zj-tab.nvim: refresh tab title on focus",
  })

  -- restore original tab name on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() module.teardown(true) end,
    desc = "Restore original Zellij tab name on exit",
  })

  -- load user commands
  vim.api.nvim_create_user_command(
    "ZJTabRefresh",
    function() module.refresh() end,
    { desc = "Force refresh of the Zellij tab name", nargs = 0 }
  )

  vim.api.nvim_create_user_command(
    "ZJTabToggle",
    function() module.toggle() end,
    { desc = "Toggle zj-tab.nvim", nargs = 0 }
  )

  schedule_rename_tab(true)
end

return module
