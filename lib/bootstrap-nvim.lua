-- Run by install.sh and install.ps1 right after the config is copied:
--   nvim --headless --cmd 'lua dofile(vim.env.DEVKIT_BOOTSTRAP)'
-- --cmd loads this before the config; the work starts once startup has finished.
-- Plugins must install. Language servers, parsers and Pyrefly are best effort, so a
-- machine without Node.js or a C compiler still ends up with a working editor.
-- Our progress goes to stderr (the terminal); Neovim's own output goes to stdout (the log).
local warnings = 0
local source = vim.fs.dirname(vim.fs.dirname(vim.env.DEVKIT_BOOTSTRAP))
local fallback_languages = { "lua", "luadoc", "printf", "vim", "vimdoc", "python", "bash", "json", "toml", "html", "css" }

local function say(message)
  io.stderr:write("  ", message, "\n")
end

local function warn(message)
  warnings = warnings + 1
  io.stderr:write("warning: ", message, "\n")
end

local function plugins()
  say "plugins: restoring the commits pinned in lazy-lock.json"
  require("lazy").restore { wait = true, show = false }
  local config = require "lazy.core.config"
  for _, notification in ipairs(config.spec.notifs or {}) do
    if notification.level >= vim.log.levels.ERROR then
      error("plugin specification: " .. notification.msg)
    end
  end
  local missing = {}
  for name, plugin in pairs(config.plugins) do
    if not plugin._.installed then
      missing[#missing + 1] = name
    end
    for _, task in ipairs(plugin._.tasks or {}) do
      if task:has_errors() then
        warn(name .. ": " .. vim.trim(task:output()))
      end
    end
  end
  if #missing > 0 then
    table.sort(missing)
    error("plugins failed to install: " .. table.concat(missing, ", "))
  end
  -- Read the pins from the source copy: lazy may already have rewritten the config's lockfile.
  local lockfile = source .. "/config/nvim/lazy-lock.json"
  local pinned = vim.json.decode(table.concat(vim.fn.readfile(lockfile), "\n"))
  for name, plugin in pairs(config.plugins) do
    local entry = pinned[name]
    if entry and not plugin._.is_local then
      local head = vim.trim(vim.fn.system { "git", "-C", plugin.dir, "rev-parse", "HEAD" })
      if vim.v.shell_error ~= 0 or head ~= entry.commit then
        warn(name .. " is not at its pinned commit " .. entry.commit:sub(1, 7))
      end
    end
  end
end

-- Installs the Mason packages listed in chadrc.lua and calls done() when they finish.
local function language_servers(done)
  local loaded, registry = pcall(function()
    require("lazy").load { plugins = { "mason.nvim" } }
    return require "mason-registry"
  end)
  if not loaded then
    warn("Mason did not load: " .. tostring(registry))
    return done()
  end
  local names = (require("chadrc").mason or {}).pkgs or {}
  say("language servers: " .. table.concat(names, ", "))
  registry.refresh(function(refreshed)
    if not refreshed then
      warn "could not download the Mason registry, so no language servers were installed"
      return done()
    end
    local pending = 0
    local function finished()
      pending = pending - 1
      if pending == 0 then
        done()
      end
    end
    for _, name in ipairs(names) do
      local found, package = pcall(registry.get_package, name)
      if not found then
        warn("Mason has no package named " .. name)
      elseif not package:is_installed() then
        pending = pending + 1
        package:install(
          {},
          vim.schedule_wrap(function(success, result)
            if not success then
              if tostring(result):find("PLATFORM_UNSUPPORTED", 1, true) then
                warn(name .. " has no build for this platform")
              else
                local npm = tostring(package.spec.source.id):match "^pkg:npm/" and vim.fn.executable "npm" == 0
                warn(name .. " was not installed" .. (npm and " (it needs Node.js and npm)" or ""))
              end
            end
            finished()
          end)
        )
      end
    end
    if pending == 0 then
      done()
    end
  end)
end

-- Starts compiling the parsers from the nvim-treesitter spec; returns the task and languages.
local function parsers()
  local ok, languages = pcall(function()
    local plugin = require("lazy.core.config").plugins["nvim-treesitter"]
    return require("lazy.core.plugin").values(plugin, "opts", false).ensure_installed
  end)
  if not ok or type(languages) ~= "table" or #languages == 0 then
    languages = fallback_languages
  end
  local needs = {}
  if vim.fn.executable "tree-sitter" == 0 then
    needs[#needs + 1] = "the tree-sitter CLI"
  end
  for _, tool in ipairs { "curl", "tar" } do
    if vim.fn.executable(tool) == 0 then
      needs[#needs + 1] = tool
    end
  end
  -- On Windows the CLI also finds Visual Studio's compiler outside PATH.
  local compilers = vim.tbl_filter(function(name)
    return vim.fn.executable(name) == 1
  end, { "cc", "gcc", "clang", "zig", "cl" })
  if vim.env.DEVKIT_NO_COMPILER == "1" or (vim.fn.has "win32" == 0 and #compilers == 0) then
    needs[#needs + 1] = "a C compiler"
  end
  if #needs > 0 then
    warn(
      "syntax parsers need "
        .. table.concat(needs, ", ")
        .. ", so highlighting falls back to regex for: "
        .. table.concat(languages, ", ")
    )
    return nil, languages
  end
  say("syntax parsers: " .. table.concat(languages, ", "))
  require("lazy").load { plugins = { "nvim-treesitter" } }
  return require("nvim-treesitter").install(languages), languages
end

local function main()
  plugins()
  local servers_done = false
  language_servers(function()
    servers_done = true
  end)
  local task, languages = parsers()
  if task then
    local finished, err = pcall(task.wait, task, 15 * 60 * 1000)
    if not finished then
      warn("parser installation stopped: " .. tostring(err))
    end
    local installed = require("nvim-treesitter").get_installed "parsers"
    local missing = vim.tbl_filter(function(language)
      return not vim.tbl_contains(installed, language)
    end, languages)
    if #missing > 0 then
      local hint = vim.fn.has "win32" == 1 and " (Windows needs a C compiler such as Visual Studio Build Tools)" or ""
      warn("these syntax parsers did not build: " .. table.concat(missing, ", ") .. hint)
    end
  end
  if not vim.wait(15 * 60 * 1000, function()
    return servers_done
  end, 200) then
    warn "language servers were still installing after 15 minutes; open :Mason to finish"
  end
  if vim.fn.executable "pyrefly" == 0 then
    warn "pyrefly is not installed, so Python files have no language server"
  end
end

-- Headless Neovim prints messages (such as each parser build step) to stderr, between our
-- lines. Plugins capture nvim_echo when they load, so replace it before the config runs.
vim.api.nvim_echo = function(chunks)
  for _, chunk in ipairs(chunks) do
    io.stdout:write(chunk[1])
  end
  io.stdout:write "\n"
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local ok, err = xpcall(main, debug.traceback)
    io.stdout:flush()
    if not ok then
      io.stderr:write("error: ", tostring(err), "\n")
      vim.cmd "cquit 1"
    end
    say(warnings == 0 and "editor ready" or ("editor ready with " .. warnings .. " warning(s)"))
    vim.cmd "qa!"
  end,
})
