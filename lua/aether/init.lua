-- Aether colorscheme for Neovim
-- Maintainer: Bjarne Øverli
-- License: MIT

local config = require("aether.config")

local M = {}

--- Load the colorscheme with optional Ghostty theme sync
---@param opts? aether.Config
function M.load(opts)
  opts = require("aether.config").extend(opts)

  -- If sync_terminal is enabled, read Ghostty theme colors
  if opts.sync_terminal then
    local terminal = require("aether.terminal")
    local base16 = terminal.get_base16()
    if base16 then
      opts.colors = vim.tbl_deep_extend("force", base16, opts.colors or {})
    end
  end

  return require("aether.theme").setup(opts)
end

M.setup = config.setup

return M
