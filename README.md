
# zj-tab.nvim

<div align="center">
    <img src="preview.png" alt="zj-tab.nvim preview" width="800">
</div>
<br>

A Neovim plugin that automatically updates your [Zellij](https://zellij.dev) tab names 
to match the active buffer.

## Features

- Automatically renames the current Zellij tab when switching buffers, tabs, or terminals.
- Optional [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) support for 
  file icons.
- Preserves the pre-Neovim tab name and restores it on exin.
- Detects when Neovim is run outside of Zellij, and if so, doesn't attempt to rename tabs.
- Optionally renames tab to the full path of the file.

## Installation

Requirements:

- [Zellij](https://zellij.dev) ≥ 0.40
- Neovim ≥ 0.8
- If using devicons:
    - [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for icons  
    - A Nerd Font 

Using **lazy.nvim**:

```lua
{ 
    "wizardling1/zj-tab.nvim", 
    opts = {
        -- Example options:
        enable_icons = true,
        max_width = 40
    } 
}
```

## Commands

- `:ZJTabRefresh` - force an immediate update of the Zellij tab name
- `:ZJTabToggle` - toggle the plugin on or off (restores original tab name when disabled)

## Configuration

Defaults are shown below.

```lua

opts = {
  -- Tab name behavior
  max_width = 40,                 -- Maximum total width for the Zellij tab name
  max_directories = 5,            -- Limit for displayed directories in paths before truncation
  show_path_for_file = false,     -- Show full path instead of just filename for files
  show_path_for_directory = false,-- Show full path instead of just directory name for directories

  -- Icons
  enable_icons = true,            -- Enable nvim-web-devicons 
  multi_buffer_icon = "",        -- Icon prefix when multiple buffers are open in a tab
  directory_icon = "",           -- Icon used for directories
  default_icon = "",             -- Fallback icon for files without an assigned icon

  -- Fallbacks
  fallback_original_tab_name = "Tab",   -- Used if original Zellij tab name cannot be restored
  fallback_buffer_name = "[No Name]",   -- Used for unnamed buffers

  -- Runtime behavior
  debounce_milliseconds = 20,     -- Delay before renaming tab after a change
  enable_debug_logs = false,      -- Print debug messages for troubleshooting
}
```

## License

[LICENSE](./LICENSE)
