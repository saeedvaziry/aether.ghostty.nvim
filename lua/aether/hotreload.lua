-- Hot reload configuration for aether.nvim
-- Provides automatic reloading when the plugin or config changes
-- @module aether.hotreload

local M = {}

-- Configuration constants
local LAZY_RELOAD_DELAY_MS = 100
local OMARCHY_RELOAD_DELAY_MS = 100
local OMARCHY_THEME_PATH = vim.fn.expand("~/.config/omarchy/current/theme/neovim.lua")

-- Patterns for module matching
local AETHER_MODULE_PATTERN = "^aether"
local LUALINE_THEME_PATTERN = "^lualine%.themes%.aether"

--- Check if aether is the currently active colorscheme
--- @return boolean
local function is_aether_active()
  return vim.g.colors_name == "aether"
end

--- Clear all aether-related modules from package cache
--- @param include_config boolean Whether to also clear the config module
local function clear_aether_modules(include_config)
  for module_name in pairs(package.loaded) do
    local is_aether_module = module_name:match(AETHER_MODULE_PATTERN)
    local is_lualine_theme = module_name:match(LUALINE_THEME_PATTERN)
    local is_config_module = module_name == "aether.config"

    if (is_aether_module or is_lualine_theme) and (include_config or not is_config_module) then
      package.loaded[module_name] = nil
    end
  end
end

--- Clear all highlight groups and reset syntax
local function clear_highlights()
  vim.cmd("highlight clear")

  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end

  vim.g.colors_name = nil
end

--- Trigger post-reload updates
local function trigger_post_reload_events()
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "aether", modeline = false })
  vim.cmd("redraw!")
end

--- Load aether theme with given options
--- @param opts table|nil Theme options
--- @return boolean success
local function load_theme(opts)
  local ok, aether = pcall(require, "aether")
  if not ok then
    vim.notify("Failed to load aether.nvim", vim.log.levels.ERROR)
    return false
  end

  if opts then
    aether.setup(opts)
  end

  aether.load()
  return true
end

--- Check if the theme spec is for aether
--- @param theme_spec table Theme specification
--- @return boolean
local function is_aether_theme(theme_spec)
  if not theme_spec or not theme_spec[1] then
    return false
  end

  local plugin_name = theme_spec[1][1] or theme_spec[1].name
  return plugin_name and plugin_name:match("aether")
end

--- Get fresh theme options from lazy.nvim config
--- @return table|nil opts Theme options or nil if not found
local function get_theme_opts()
  package.loaded["plugins.theme"] = nil

  local ok, theme_spec = pcall(require, "plugins.theme")
  if not ok or not is_aether_theme(theme_spec) then
    return nil
  end

  return theme_spec[1].opts
end

--- Reload the aether colorscheme with current configuration
--- This preserves the existing config module to maintain user options
local function reload_colorscheme()
  clear_aether_modules(false) -- Don't clear config

  vim.schedule(function()
    clear_highlights()

    if not load_theme() then
      return
    end

    trigger_post_reload_events()
    vim.notify("aether.nvim reloaded", vim.log.levels.INFO)
  end)
end

--- Reload the aether colorscheme with fresh options from config
--- This clears ALL modules including config and reloads with new options
--- This works both when aether is active (reload) and when switching to aether (load)
local function reload_with_fresh_opts()
  local opts = get_theme_opts()
  if not opts then
    -- Theme is not aether or failed to load, skip reload
    return
  end

  local was_active = is_aether_active()

  clear_aether_modules(true) -- Clear everything including config
  clear_highlights()

  if not load_theme(opts) then
    return
  end

  trigger_post_reload_events()

  if was_active then
    vim.notify("aether.nvim reloaded with new colors", vim.log.levels.INFO)
  else
    vim.notify("aether.nvim loaded", vim.log.levels.INFO)
  end
end

--- Setup autocmd for lazy.nvim reload events
local function setup_lazy_reload_autocmd()
  vim.api.nvim_create_autocmd("User", {
    pattern = "LazyReload",
    callback = function(event)
      -- Only handle aether plugin reloads
      if event.data and event.data ~= "aether.nvim" and event.data ~= "aether" then
        return
      end

      -- Defer to ensure lazy.nvim completes its reload process
      -- Note: We check if the config has aether inside reload_with_fresh_opts()
      -- instead of checking is_aether_active() here, because we want to reload
      -- when switching TO aether, not just when aether is already active
      vim.defer_fn(reload_with_fresh_opts, LAZY_RELOAD_DELAY_MS)
    end,
    desc = "Reload aether theme when lazy.nvim detects changes",
  })
end

--- Setup autocmd for plugin development file changes
local function setup_dev_file_watcher()
  local plugin_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = plugin_path .. "/lua/**/*.lua",
    callback = function()
      if is_aether_active() then
        reload_colorscheme()
      end
    end,
    desc = "Reload aether theme on plugin file changes during development",
  })
end

--- Setup autocmd for external theme config file changes (omarchy)
local function setup_external_config_watcher()
  if vim.fn.filereadable(OMARCHY_THEME_PATH) ~= 1 then
    return
  end

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = OMARCHY_THEME_PATH,
    callback = function()
      if not is_aether_active() then
        return
      end

      -- Defer longer to allow other reload mechanisms to complete first
      vim.defer_fn(reload_with_fresh_opts, OMARCHY_RELOAD_DELAY_MS)
    end,
    desc = "Reload aether theme when omarchy config changes",
  })
end

--- Setup user command for manual reloading
local function setup_reload_command()
  vim.api.nvim_create_user_command("AetherReload", function()
    if is_aether_active() then
      reload_colorscheme()
    else
      vim.notify("aether is not the active colorscheme", vim.log.levels.WARN)
    end
  end, { desc = "Manually reload aether colorscheme" })
end

--- Setup user command for syncing with Ghostty terminal colors
local function setup_sync_terminal_command()
  vim.api.nvim_create_user_command("AetherSyncTerminal", function()
    local terminal = require("aether.terminal")

    local theme_name = terminal.get_theme_name()
    if not theme_name then
      vim.notify("Could not find Ghostty theme in config", vim.log.levels.WARN)
      return
    end

    local base16 = terminal.get_base16()
    if not base16 then
      vim.notify("Could not read Ghostty theme: " .. theme_name, vim.log.levels.WARN)
      return
    end

    -- Get current config options
    local aether_config = require("aether.config")
    local opts = vim.deepcopy(aether_config.options or aether_config.defaults)

    -- Merge Ghostty colors
    opts.colors = vim.tbl_deep_extend("force", base16, opts.colors or {})

    -- Clear and reload
    clear_aether_modules(true)
    clear_highlights()

    local ok, aether = pcall(require, "aether")
    if not ok then
      vim.notify("Failed to load aether.nvim", vim.log.levels.ERROR)
      return
    end

    aether.setup(opts)
    aether.load()

    trigger_post_reload_events()
    vim.notify("aether.nvim synced with Ghostty theme: " .. theme_name, vim.log.levels.INFO)
  end, { desc = "Sync aether colorscheme with Ghostty terminal theme" })
end

--- Initialize hot reload functionality
--- Sets up autocmds and user commands for automatic theme reloading
function M.setup()
  setup_lazy_reload_autocmd()
  setup_dev_file_watcher()
  setup_external_config_watcher()
  setup_reload_command()
  setup_sync_terminal_command()
end

return M
