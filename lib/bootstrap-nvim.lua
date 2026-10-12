local function bootstrap()
  assert(vim.fn.has "nvim-0.12" == 1, "Neovim 0.12 or later is required")
  local function check_plugins()
    local config = require "lazy.core.config"
    for _, notification in ipairs(config.spec.notifs or {}) do
      assert(notification.level < vim.log.levels.ERROR, "Plugin specification failed: " .. notification.msg)
    end
    for name, plugin in pairs(config.plugins) do
      assert(plugin._.installed, "Plugin is not installed: " .. name)
      for _, task in ipairs(plugin._.tasks or {}) do
        assert(not task:has_errors(), "Plugin task failed: " .. name .. ": " .. task:output())
      end
    end
  end
  check_plugins()
  require("lazy").restore { wait = true, clear = false }
  check_plugins()
  local original_lock = vim.env.DEVKIT_ENV .. "/source/config/nvim/lazy-lock.json"
  local expected = vim.json.decode(table.concat(vim.fn.readfile(original_lock), "\n"))
  for name, plugin in pairs(require("lazy.core.config").plugins) do
    if not plugin._.is_local then
      local locked = assert(expected[name], "Plugin has no pinned revision: " .. name)
      local actual = vim.fn.system { "git", "-C", plugin.dir, "rev-parse", "HEAD" }
      assert(vim.v.shell_error == 0 and vim.trim(actual) == locked.commit,
        "Plugin does not match its pinned revision: " .. name)
    end
  end
  require("lazy").load { plugins = { "nvim-treesitter", "mason.nvim", "nvim-lspconfig" } }
  assert(vim.v.errmsg == "", "Neovim startup reported: " .. vim.v.errmsg)

  local registry = require "mason-registry"
  local refreshed, refresh_ok = false, false
  registry.refresh(function(success)
    refresh_ok = success
    refreshed = true
  end)
  assert(vim.wait(120000, function() return refreshed end, 100), "Mason registry refresh timed out")
  assert(refresh_ok, "Mason registry refresh failed")

  local packages = { "stylua", "html-lsp", "css-lsp" }
  for _, name in ipairs(packages) do
    local package = registry.get_package(name)
    if not package:is_installed() then
      local finished, succeeded = false, false
      package:install():once("closed", function()
        succeeded = package:is_installed()
        finished = true
      end)
      assert(vim.wait(300000, function() return finished end, 100), name .. " install timed out")
      assert(succeeded, name .. " install failed")
    end
  end

  local languages = { "lua", "luadoc", "printf", "vim", "vimdoc", "python", "bash", "json", "toml", "html", "css" }
  require("nvim-treesitter").install(languages):wait(300000)
  local installed = require("nvim-treesitter").get_installed("parsers")
  for _, language in ipairs(languages) do
    assert(vim.tbl_contains(installed, language), "Missing parser: " .. language)
  end
  assert(vim.fn.executable "pyrefly" == 1, "Pyrefly is missing from PATH")
end

local ok, err = pcall(bootstrap)
if not ok then
  vim.api.nvim_err_writeln(tostring(err))
  vim.cmd "cquit 1"
end
vim.cmd "qa!"
