
local M = {}
M.enabled = true

local Config = {
  max_tabname_width = 20,
  debounce_ms = 20,
  enable_devicons = true,
  multi_icon = "",
  default_icon = "",
  fallback_restored_tabname = "Tab",
  debug = false,
}

local State = {
  rename_tab_fn = nil,
  autocmd_group = nil,
  pending = false,
  last_set_tabname = nil,
  original_name = { known = false, name = Config.fallback_restored_tabname }
}

-- --- Utilities ---

local function merge_into(dst, src)
  if not src then return dst end
  for k,v in pairs(src) do dst[k] = v end
  return dst
end

local function notify(msg, level)
  vim.notify("zj-tab.nvim: " .. msg, level, { title = "zj-tab.nvim" })
end

local function dlog(msg)
  if Config.debug then notify(msg, vim.log.levels.DEBUG) end
end

local function in_zellij()
  return (vim.env.ZELLIJ ~= nil) and vim.fn.executable("zellij") == 1
end

local function zellij_action(args, opts)
  opts = opts or {}
  opts.detach = true
  return vim.fn.jobstart(vim.list_extend({ "zellij", "action" }, args), opts)
end

-- --- Saving and restoring pre-nvim tab name ---

local function parse_focused_tab_name(dump)
  if not dump or dump == "" then return nil end
  for line in dump:gmatch("[^\r\n]+") do
    if line:find("tab") and line:find("focus%s*=%s*true") then
      return line:match('name%s*=%s*"([^"]+)"')
    end
  end
  return nil
end

local function capture_original_name()
  if State.original_name.known then return end

  local stderr_buf = {}

  vim.fn.jobstart({ "zellij", "action", "dump-layout" }, {
    stdout_buffered = true,
    stderr_buffered = true,

    on_stdout = function(_, data)
      local text = table.concat(data or {}, "\n")
      local parsed = parse_focused_tab_name(text)
      if parsed and parsed ~= "" then
        State.original_name.name = parsed
      else
        notify(
          "Could not discover original tab name: will restore to fallback name `"
            .. Config.fallback_restored_tabname .. "`.",
          vim.log.levels.WARN
        )
      end
      State.original_name.known = true
      dlog("captured original tab_name: " .. tostring(State.original_name.name))
    end,

    on_stderr = function(_, data)
      if data then vim.list_extend(stderr_buf, data) end
    end,

    on_exit = function(_, code)
      if code ~= 0 then
        local msg = vim.trim(table.concat(stderr_buf, "\n"))
        if msg ~= "" then dlog("dump-layout stderr: " .. msg) end
      end
    end,
  })
end

-- --- Devicons ---

local function get_devicons_get_icon()
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    return devicons.get_icon
  else
    notify(
      "Could not find nvim-web-devicons plugin. Falling back to the default file icon.",
      vim.log.levels.WARN
    )
    return function(_, _, _)
        return Config.default_icon
    end
  end
end

local function prefix_devicon(str, get_icon)
  if type(str) ~= "string" or str == "" then
    return Config.default_icon
  else
    local fname = vim.fn.fnamemodify(str, ":t")
    local ext   = vim.fn.fnamemodify(fname, ":e")
    local icon  = get_icon(fname, ext, { default = true })
    return (icon or Config.default_icon) .. " " .. str
  end
end

local function prefix_text_if(str, prefix, cond)
  if cond then
    if str == "" then
      return prefix
    else
      return prefix .. " " .. str
    end
  else
    return str
  end
end

-- --- Tab renaming ---

local function buffer_count()
  return #vim.fn.getbufinfo({ buflisted = 1 })
end

local function truncate_name(name, max_width)
  local w = vim.fn.strdisplaywidth(name)
  if w <= max_width then
    return name
  else
    return vim.fn.strcharpart(name, 0, max_width - 1) .. "…"
  end
end

local function buffer_name()
  local name = vim.fn.expand("%:t")
  if name == "" then name = "[No Name]" end
  return name
end

local function rename_tab_normal()
  local name =
    truncate_name(
      buffer_name(),
      Config.max_tabname_width
    )

  if name ~= State.last_set_tabname then
    State.last_set_tabname = name
    zellij_action({"rename-tab", name})
  end
end

local function rename_tab_devicons(get_icon)
  local name =
    truncate_name(
      prefix_text_if(
        prefix_devicon(
          buffer_name(),
          get_icon
        ),
        Config.multi_icon,
        buffer_count() > 1
      ),
      Config.max_tabname_width
    )

  if name ~= State.last_set_tabname then
    State.last_set_tabname = name
    zellij_action({"rename-tab", name})
  end
end

local function get_rename_tab_fn(enable_devicons, get_icon)
  if enable_devicons then
    return function() rename_tab_devicons(get_icon) end
  else
    return rename_tab_normal
  end
end

local function schedule_rename_tab(force)
  if State.pending then return end
  State.pending = true
  if force then State.last_set_tabname = nil end
  vim.defer_fn(function()
    if State.rename_tab_fn then State.rename_tab_fn() end
    State.pending = false
  end, Config.debounce_ms)
end

-- --- Plugin API ---

M.config = Config

function M.refresh()
  schedule_rename_tab(true)
end

function M.teardown(restore)
  if restore then
    zellij_action({ "rename-tab", State.original_name.name })
  end
  if State.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, State.autocmd_group)
    State.autocmd_group = nil
  end
  State.rename_tab_fn = nil
  State.pending = false
  State.last_set_tabname = nil
end

function M.toggle()
  if M.enabled then
    M.teardown(true)
    M.enabled = false
  else
    M.setup()
    M.enabled = true
  end
end

function M.setup(opts)
  pcall(vim.api.nvim_del_user_command, "ZJTabRefresh")
  pcall(vim.api.nvim_del_user_command, "ZJTabToggle")
  pcall(vim.api.nvim_del_augroup_by_name, "ZJTab")

  merge_into(Config, opts)

  if not in_zellij() then
    return
  end

  State.autocmd_group = vim.api.nvim_create_augroup("ZJTab", { clear = true })

  if Config.enable_devicons then
    State.rename_tab_fn = get_rename_tab_fn(true, get_devicons_get_icon())
  else
    State.rename_tab_fn = get_rename_tab_fn(false)
  end

  -- rename tab on buffer enter, when file name changes, tab enter, or terminal open
  vim.api.nvim_create_autocmd({
    "BufEnter",
    "BufFilePost",
    "BufWritePost",
    "TabEnter",
    "TermOpen",
  }, {
    group = State.autocmd_group,
    callback = function() schedule_rename_tab(false) end,
    desc = "zj-tab.nvim: update Zellij tab title"
  })

  -- force rename tab on focus gained
  -- (important if other code is modifying zellij tab names in new zellij panes)
  vim.api.nvim_create_autocmd("FocusGained",{
    group = State.autocmd_group,
    callback = function() schedule_rename_tab(true) end,
    desc = "zj-tab.nvim: refresh tab title on focus",
  })

  -- restore original tab name on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() M.teardown(true) end,
    desc = "Restore original Zellij tab name on exit",
  })

  vim.api.nvim_create_user_command(
    "ZJTabRefresh",
    function() M.refresh() end,
    { desc = "Force refresh of the Zellij tab name", nargs = 0 }
  )

  vim.api.nvim_create_user_command(
    "ZJTabToggle",
    function() M.toggle() end,
    { desc = "Toggle zj-tab.nvim", nargs = 0 }
  )

  capture_original_name()
  schedule_rename_tab(true)
end

return M

