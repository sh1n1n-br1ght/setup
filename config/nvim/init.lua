vim.g.base46_cache = vim.fn.stdpath "data" .. "/base46/"
vim.g.mapleader = " "

-- bootstrap lazy and all plugins
local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"
local lockfile = vim.fn.stdpath "config" .. "/lazy-lock.json"
local lock = vim.json.decode(table.concat(vim.fn.readfile(lockfile), "\n"))
local lazy_commit = assert(lock["lazy.nvim"] and lock["lazy.nvim"].commit, "lazy.nvim commit is missing from lazy-lock.json")
assert(lazy_commit:match("^[0-9a-f]+$") and #lazy_commit == 40, "Invalid lazy.nvim lock commit")

local function git(args)
  local output = vim.fn.system(args)
  assert(vim.v.shell_error == 0, "lazy.nvim bootstrap failed: " .. output)
  return vim.trim(output)
end

if not vim.uv.fs_stat(lazypath) then
  local repo = "https://github.com/folke/lazy.nvim.git"
  git { "git", "clone", "--filter=blob:none", "--no-checkout", repo, lazypath }
  git { "git", "-C", lazypath, "checkout", "--detach", lazy_commit }
end

assert(git { "git", "-C", lazypath, "rev-parse", "HEAD" } == lazy_commit,
  "lazy.nvim differs from its lockfile; preserve local changes and restore the locked commit before continuing")

vim.opt.rtp:prepend(lazypath)

local lazy_config = require "configs.lazy"

-- load plugins
local plugins = {
  {
    "NvChad/NvChad",
    lazy = false,
    branch = "v2.5",
    import = "nvchad.plugins",
  },

  { import = "plugins" },
}

-- Imported specs arrive in several install rounds. Keep the original pins even
-- if lazy rewrites its lockfile before those specs have finished loading.
for name, revision in pairs(lock) do
  plugins[#plugins + 1] = { name, commit = revision.commit, optional = true }
end
require("lazy").setup(plugins, lazy_config)

-- load theme
dofile(vim.g.base46_cache .. "defaults")
dofile(vim.g.base46_cache .. "statusline")

require "options"
require "autocmds"

vim.schedule(function()
  require "mappings"
end)
