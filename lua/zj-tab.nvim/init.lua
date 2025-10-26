local M = {}

local devicons_ok, devicons = pcall(require, "nvim-web-devicons")
local MULTI_ICON = ""

local function icon_for(bufnr)
  bufnr = bufnr or 0
  if devicons_ok then
    local name  = vim.api.nvim_buf_get_name(bufnr)
    local fname = name ~= "" and vim.fn.fnamemodify(name, ":t") or ""
    local ext   = fname ~= "" and vim.fn.fnamemodify(fname, ":e") or ""
    local icon  = devicons.get_icon(fname, ext, { default = true })
    if icon and icon ~= "" then return icon end
  end
  return ""
end

local function listed_buf_count()
  return #vim.fn.getbufinfo({ buflisted = 1 })
end

local function title_for(bufnr)
  bufnr = bufnr or 0
  local name = vim.fn.expand("%:t"); if name == "" then name = "[No Name]" end
  local title = icon_for(bufnr) .. " " .. name
  if listed_buf_count() > 1 then
    title = MULTI_ICON .. " " .. title
  end
  if #title > 40 then title = title:sub(1, 37) .. "..." end
  return title
end

-- --- de-dupe + debounce ---
local last_sent = nil
local pending   = false
local function send_title()
  if not vim.env.ZELLIJ then return end
  local t = title_for(0)
  if t == last_sent then return end
  last_sent = t
  vim.fn.jobstart({ "zellij", "action", "rename-tab", t }, { detach = true })
end

local function schedule_send()
  if pending then return end
  pending = true
  vim.defer_fn(function()
    pending = false
    send_title()
  end, 5)
end

local aug

function M.setup()
  if aug then return end
  aug = vim.api.nvim_create_augroup("ZJTab", { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufFilePost", "BufWritePost", "TermEnter", "DirChanged", "FileType" },
    { group = aug, callback = schedule_send, desc = "zjtab.nvim: update Zellij tab title" }
  )
  schedule_send()
end

function M.refresh()
  schedule_send()
end

return M

