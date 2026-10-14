-- Checks an installed editor:
--   nvim --headless -c 'lua dofile("tests/check_editor.lua")'
-- DEVKIT_EXPECT=plugins only requires the plugins (for machines without a compiler or Node.js).
local failures = {}
local function check(ok, message)
  if not ok then
    failures[#failures + 1] = message
  end
end

local config = require "lazy.core.config"
check(config.plugins.NvChad ~= nil, "NvChad is not configured")
for name, plugin in pairs(config.plugins) do
  check(plugin._.installed, "plugin not installed: " .. name)
end
check(require("chadrc").base46.theme == "gruvbox_light", "chadrc.lua was not loaded")
check(vim.o.guicursor:find("block-Cursor", 1, true) ~= nil, "the cursor does not use the theme's Cursor colors")
check(vim.g.base46_cache and vim.uv.fs_stat(vim.g.base46_cache .. "defaults") ~= nil, "the NvChad theme cache is missing")

if vim.env.DEVKIT_EXPECT ~= "plugins" then
  require("lazy").load { plugins = { "nvim-treesitter", "mason.nvim" } }
  local parsers = require("nvim-treesitter").get_installed "parsers"
  for _, language in ipairs { "lua", "python", "bash", "json", "toml", "html", "css" } do
    check(vim.tbl_contains(parsers, language), "parser not installed: " .. language)
  end
  local registry = require "mason-registry"
  local compiler = require "mason-core.installer.compiler"
  for _, name in ipairs(require("chadrc").mason.pkgs) do
    -- Some tools publish no build for every platform (stylua has none for Windows on Arm).
    local supported = compiler.parse(registry.get_package(name).spec, {}):err_or_nil() ~= "PLATFORM_UNSUPPORTED"
    check(not supported or registry.is_installed(name), "Mason package not installed: " .. name)
  end
  check(vim.fn.executable "pyrefly" == 1, "pyrefly is not on PATH")
end

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n"), "\n")
  vim.cmd "cquit 1"
end
io.stdout:write "editor checks passed\n"
vim.cmd "qa!"
