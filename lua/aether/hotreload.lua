-- Hot reload configuration for aether.nvim
-- Provides automatic reloading when the plugin or config changes
-- @module aether.hotreload

local M = {}

-- Configuration constants
local LAZY_RELOAD_DELAY_MS = 100
local OMARCHY_RELOAD_DELAY_MS = 100
local GHOSTTY_RELOAD_DELAY_MS = 200
local OMARCHY_THEME_PATH = vim.fn.expand("~/.config/omarchy/current/theme/neovim.lua")
local GHOSTTY_CONFIG_PATH = vim.fn.expand("~/.config/ghostty/config")

-- Patterns for module matching
local AETHER_MODULE_PATTERN = "^aether"
local LUALINE_THEME_PATTERN = "^lualine%.themes%.aether"

-- File watcher state
local ghostty_watcher = nil
local last_ghostty_theme = nil

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

--- Sync with Ghostty theme (reusable logic)
---@param silent? boolean Suppress notifications
---@return boolean success
local function sync_ghostty_theme(silent)
  -- Read Ghostty config fresh (don't use cached module)
  local config_path = vim.fn.expand("~/.config/ghostty/config")
  local f = io.open(config_path, "r")
  if not f then
    if not silent then
      vim.notify("Could not read Ghostty config", vim.log.levels.WARN)
    end
    return false
  end
  local config_content = f:read("*a")
  f:close()

  -- Parse theme name from config
  local theme_name = config_content:match('theme%s*=%s*"?([^"\n]+)"?')
  if not theme_name then
    if not silent then
      vim.notify("Could not find Ghostty theme in config", vim.log.levels.WARN)
    end
    return false
  end
  theme_name = theme_name:gsub("%s+$", "") -- trim trailing whitespace

  -- Skip if theme hasn't changed
  if theme_name == last_ghostty_theme and silent then
    return false
  end

  -- Find and read theme file
  local theme_paths = {
    "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/" .. theme_name,
    vim.fn.expand("~/.config/ghostty/themes/") .. theme_name,
  }

  local theme_content = nil
  for _, path in ipairs(theme_paths) do
    local tf = io.open(path, "r")
    if tf then
      theme_content = tf:read("*a")
      tf:close()
      break
    end
  end

  if not theme_content then
    if not silent then
      vim.notify("Could not read Ghostty theme: " .. theme_name, vim.log.levels.WARN)
    end
    return false
  end

  -- Parse theme colors
  local palette = {}
  local background, foreground

  for line in theme_content:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
    if key == "palette" then
      local idx, hex = value:match("^(%d+)=(#%x+)$")
      if idx and hex then
        palette[tonumber(idx)] = hex
      end
    elseif key == "background" then
      background = value
    elseif key == "foreground" then
      foreground = value
    end
  end

  -- Build base16 colors
  local base16 = {
    base00 = background or palette[0],
    base01 = palette[8] or palette[0],
    base02 = palette[8] or palette[0],
    base03 = palette[8] or "#585858",
    base04 = palette[7] or "#b8b8b8",
    base05 = foreground or palette[7],
    base06 = palette[15] or palette[7],
    base07 = palette[15] or "#f8f8f8",
    base08 = palette[1],
    base09 = palette[9] or palette[1],
    base0A = palette[3],
    base0B = palette[2],
    base0C = palette[6],
    base0D = palette[4],
    base0E = palette[5],
    base0F = palette[9] or palette[1],
  }

  -- Clear all aether modules
  for module_name in pairs(package.loaded) do
    if module_name:match("^aether") or module_name:match("^lualine%.themes%.aether") then
      package.loaded[module_name] = nil
    end
  end

  -- Clear highlights
  vim.cmd("highlight clear")
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end
  vim.g.colors_name = nil

  -- Load fresh aether module
  local ok, aether = pcall(require, "aether")
  if not ok then
    if not silent then
      vim.notify("Failed to load aether.nvim: " .. tostring(aether), vim.log.levels.ERROR)
    end
    return false
  end

  -- Setup with Ghostty colors
  local aether_config = require("aether.config")
  local opts = vim.deepcopy(aether_config.defaults)
  opts.colors = base16
  opts.sync_terminal = true

  aether.setup(opts)
  aether.load()

  -- Trigger events
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "aether", modeline = false })
  vim.cmd("redraw!")

  last_ghostty_theme = theme_name

  return true
end

--- Setup file watcher for Ghostty config
local function setup_ghostty_watcher()
  -- Only watch if file exists
  if vim.fn.filereadable(GHOSTTY_CONFIG_PATH) ~= 1 then
    return
  end

  -- Store initial theme
  local terminal = require("aether.terminal")
  last_ghostty_theme = terminal.get_theme_name()

  -- Use libuv file watcher for config file changes
  local uv = vim.uv or vim.loop
  ghostty_watcher = uv.new_fs_event()

  if ghostty_watcher then
    ghostty_watcher:start(GHOSTTY_CONFIG_PATH, {}, function(err, filename, events)
      if err then
        return
      end

      -- Schedule to run in main loop
      vim.schedule(function()
        -- Check if aether is active and sync_terminal is enabled
        if not is_aether_active() then
          return
        end

        local config = require("aether.config")
        local opts = config.options or config.defaults
        if not opts.sync_terminal then
          return
        end

        -- Debounce: wait a bit for file to be fully written
        vim.defer_fn(function()
          sync_ghostty_theme(true)
        end, GHOSTTY_RELOAD_DELAY_MS)
      end)
    end)
  end

  -- Also check on FocusGained - useful when switching back to Neovim
  -- after changing Ghostty theme via its UI/shortcuts
  vim.api.nvim_create_autocmd("FocusGained", {
    callback = function()
      if not is_aether_active() then
        return
      end

      local config = require("aether.config")
      local opts = config.options or config.defaults
      if not opts.sync_terminal then
        return
      end

      -- Check if theme changed (silent)
      vim.defer_fn(function()
        sync_ghostty_theme(true)
      end, 100)
    end,
    desc = "Check for Ghostty theme changes on focus",
  })
end

--- Stop Ghostty file watcher
local function stop_ghostty_watcher()
  if ghostty_watcher then
    ghostty_watcher:stop()
    ghostty_watcher = nil
  end
end

--- Setup user command for syncing with Ghostty terminal colors
local function setup_sync_terminal_command()
  vim.api.nvim_create_user_command("AetherSyncTerminal", function()
    -- Force sync even if theme hasn't changed
    last_ghostty_theme = nil
    sync_ghostty_theme(false)
  end, { desc = "Sync aether colorscheme with Ghostty terminal theme" })

  -- Debug command to show current state
  vim.api.nvim_create_user_command("AetherDebug", function()
    local config_path = vim.fn.expand("~/.config/ghostty/config")
    local f = io.open(config_path, "r")
    if not f then
      print("Cannot read: " .. config_path)
      return
    end
    local content = f:read("*a")
    f:close()

    local theme_name = content:match('theme%s*=%s*"?([^"\n]+)"?')
    if theme_name then
      theme_name = theme_name:gsub("%s+$", "")
    end

    print("Ghostty config: " .. config_path)
    print("Theme name: " .. (theme_name or "NOT FOUND"))
    print("Last synced theme: " .. (last_ghostty_theme or "NONE"))
    print("colors_name: " .. (vim.g.colors_name or "NONE"))

    -- Check theme file
    local theme_path = "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/" .. (theme_name or "")
    print("Theme file exists: " .. tostring(vim.fn.filereadable(theme_path) == 1))
  end, { desc = "Debug aether Ghostty sync" })
end

--- Initialize hot reload functionality
--- Sets up autocmds and user commands for automatic theme reloading
function M.setup()
  setup_lazy_reload_autocmd()
  setup_dev_file_watcher()
  setup_external_config_watcher()
  setup_reload_command()
  setup_sync_terminal_command()
  setup_ghostty_watcher()
end

--- Stop all file watchers (call on plugin unload if needed)
function M.stop()
  stop_ghostty_watcher()
end

return M
