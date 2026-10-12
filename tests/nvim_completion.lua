local function check()
  require("lazy").load { plugins = { "nvim-cmp" } }
  local cmp = require "cmp"
  local old_feedkeys = vim.api.nvim_feedkeys
  local count = 0
  vim.api.nvim_feedkeys = function()
    count = count + 1
  end
  vim.o.virtualedit = "onemore"

  local cases = {
    { "single import", { "from tomllib import load" }, 1, false },
    { "indented import", { "def main():", "    from tomllib import load" }, 2, false },
    { "multiple imports", { "from tomllib import loads, load" }, 1, false },
    { "multiline import", { "from tomllib import (", "    load", ")" }, 2, false },
    { "unfinished multiline import", { "from tomllib import (", "    load" }, 2, false },
    { "continued import", { "from tomllib import \\", "    load" }, 2, false },
    { "function call", { "load" }, 1, true },
    { "qualified function call", { "tomllib.load" }, 1, true },
    { "call after import", { "from tomllib import load; load" }, 1, true },
    { "other language", { "load" }, 1, true, "lua" },
  }
  for _, case in ipairs(cases) do
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo.filetype = case[5] or "python"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, case[2])
    vim.api.nvim_win_set_cursor(0, { case[3], #case[2][case[3]] })
    local item = { label = "load", kind = cmp.lsp.CompletionItemKind.Function, insertText = "load" }
    count = 0
    cmp.event:emit("confirm_done", {
      entry = {
        completion_item = item,
        get_commit_characters = function() return {} end,
        get_completion_item = function() return item end,
      },
    })
    assert((count > 0) == case[4], case[1] .. ": unexpected bracket insertion count " .. count)
    print("PASS: " .. case[1])
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  vim.api.nvim_feedkeys = old_feedkeys
end

local ok, err = pcall(check)
if not ok then
  print(err)
  vim.cmd "cquit 1"
end
vim.cmd "qa!"
