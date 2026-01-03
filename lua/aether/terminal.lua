-- Ghostty terminal color detection
-- Reads Ghostty's config to get the current theme and its colors

local M = {}

-- Ghostty paths
local CONFIG_PATHS = {
  vim.fn.expand("~/.config/ghostty/config"),
  vim.fn.expand("~/Library/Application Support/com.mitchellh.ghostty/config"),
}

local THEME_PATHS = {
  "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
  vim.fn.expand("~/.config/ghostty/themes"),
  vim.fn.expand("~/Library/Application Support/com.mitchellh.ghostty/themes"),
}

--- Read a file and return its contents
---@param path string
---@return string?
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- Parse Ghostty config format (key = value)
---@param content string
---@return table<string, string>
local function parse_config(content)
  local config = {}
  for line in content:gmatch("[^\r\n]+") do
    -- Skip comments and empty lines
    if not line:match("^%s*#") and not line:match("^%s*$") then
      local key, value = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
      if key and value then
        -- Remove quotes if present
        value = value:gsub('^"(.*)"$', "%1")
        config[key] = value
      end
    end
  end
  return config
end

--- Parse Ghostty theme file
---@param content string
---@return table colors {palette={0-15}, background, foreground, cursor, selection_bg, selection_fg}
local function parse_theme(content)
  local colors = {
    palette = {},
  }

  for line in content:gmatch("[^\r\n]+") do
    if not line:match("^%s*#") and not line:match("^%s*$") then
      local key, value = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
      if key and value then
        -- Handle palette colors (palette = N=#xxxxxx)
        local index, color = key:match("^palette$"), value:match("^(%d+)=(#%x+)$")
        if index and color then
          local idx = tonumber(value:match("^(%d+)="))
          local hex = value:match("=(#%x+)$")
          if idx and hex then
            colors.palette[idx] = hex
          end
        elseif key == "background" then
          colors.background = value
        elseif key == "foreground" then
          colors.foreground = value
        elseif key == "cursor-color" then
          colors.cursor = value
        elseif key == "cursor-text" then
          colors.cursor_text = value
        elseif key == "selection-background" then
          colors.selection_bg = value
        elseif key == "selection-foreground" then
          colors.selection_fg = value
        end
      end
    end
  end

  return colors
end

--- Find and read Ghostty config file
---@return table? config Parsed config or nil
---@return string? path Path to config file
local function find_config()
  for _, path in ipairs(CONFIG_PATHS) do
    local content = read_file(path)
    if content then
      return parse_config(content), path
    end
  end
  return nil, nil
end

--- Find theme file by name
---@param theme_name string
---@return string? path
local function find_theme_file(theme_name)
  for _, base_path in ipairs(THEME_PATHS) do
    local path = base_path .. "/" .. theme_name
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
  return nil
end

--- Get current Ghostty theme name from config
---@return string? theme_name
function M.get_theme_name()
  local config = find_config()
  if config and config.theme then
    return config.theme
  end
  return nil
end

--- Get colors for a specific theme
---@param theme_name string
---@return table? colors
function M.get_theme_colors(theme_name)
  local path = find_theme_file(theme_name)
  if not path then
    return nil
  end

  local content = read_file(path)
  if not content then
    return nil
  end

  return parse_theme(content)
end

--- Get current Ghostty theme colors
---@return table? colors
function M.get_current_colors()
  local theme_name = M.get_theme_name()
  if not theme_name then
    return nil
  end
  return M.get_theme_colors(theme_name)
end

--- Map Ghostty colors to base16 palette
---@param colors table Ghostty colors from parse_theme()
---@return table base16 {base00-base0F}
function M.to_base16(colors)
  local p = colors.palette or {}
  local base16 = {}

  -- Background colors
  base16.base00 = colors.background or p[0] -- Default background
  base16.base01 = p[8] or p[0] -- Lighter background (status bars)
  base16.base02 = p[8] or p[0] -- Selection background
  base16.base03 = p[8] or "#585858" -- Comments, line numbers

  -- Foreground colors
  base16.base04 = p[7] or "#b8b8b8" -- Dark foreground
  base16.base05 = colors.foreground or p[7] -- Default foreground
  base16.base06 = p[15] or p[7] -- Light foreground
  base16.base07 = p[15] or "#f8f8f8" -- Lightest foreground

  -- Accent colors
  base16.base08 = p[1] -- Red (variables, errors)
  base16.base09 = p[9] or p[1] -- Orange (integers, constants)
  base16.base0A = p[3] -- Yellow (classes, warnings)
  base16.base0B = p[2] -- Green (strings)
  base16.base0C = p[6] -- Cyan (support, regex)
  base16.base0D = p[4] -- Blue (functions, methods)
  base16.base0E = p[5] -- Magenta (keywords)
  base16.base0F = p[9] or p[1] -- Brown (deprecated)

  return base16
end

--- Get base16 colors from current Ghostty theme
---@return table? base16
function M.get_base16()
  local colors = M.get_current_colors()
  if not colors then
    return nil
  end
  return M.to_base16(colors)
end

--- Check if running in Ghostty
---@return boolean
function M.is_ghostty()
  return vim.env.TERM_PROGRAM == "ghostty"
end

--- List available Ghostty themes
---@return string[]
function M.list_themes()
  local themes = {}
  for _, base_path in ipairs(THEME_PATHS) do
    local handle = vim.loop.fs_scandir(base_path)
    if handle then
      while true do
        local name, type = vim.loop.fs_scandir_next(handle)
        if not name then
          break
        end
        if type == "file" then
          table.insert(themes, name)
        end
      end
    end
  end
  table.sort(themes)
  return themes
end

return M
