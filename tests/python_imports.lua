-- Checks that completion in `from module import ...` lists offers only the module's members
-- (configs/python_imports.lua):
--   nvim --headless -c 'lua dofile("tests/python_imports.lua")'
local imports = require "configs.python_imports"
local failures = {}

local file = vim.fn.tempname() .. ".py"
vim.fn.writefile({}, file)
require("lazy").load { plugins = { "nvim-lspconfig" } }
vim.cmd("edit " .. vim.fn.fnameescape(file))
assert(vim.wait(30000, function()
  return #vim.lsp.get_clients { bufnr = 0, name = "pyrefly" } > 0
end, 50), "pyrefly did not start")
-- Lets the cursor sit after the last character, as it does in Insert mode.
vim.o.virtualedit = "onemore"

local function members_at(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
  local anchor = imports.anchor()
  if not anchor then
    return nil
  end
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = anchor[1], character = anchor[2] },
    context = { triggerKind = 1 },
  }
  local labels = {}
  for _, response in pairs(vim.lsp.buf_request_sync(0, "textDocument/completion", params, 30000) or {}) do
    for _, item in ipairs((response.result or {}).items or response.result or {}) do
      labels[item.label] = true
    end
  end
  return labels
end

for _, lines in ipairs {
  { "from os.path import " },
  { "from os.path import join, " },
  { "from os.path import join, e" },
  { "from os.path import (join, " },
  { "from os.path import (", "    join,", "    " },
} do
  local name = table.concat(lines, " / ")
  local labels = members_at(lines)
  if not labels then
    failures[#failures + 1] = name .. ": not recognized as an import list"
  elseif not (labels.exists and labels.isdir) or labels.print then
    failures[#failures + 1] = name .. ": expected only os.path members"
  else
    print("PASS: " .. name)
  end
end
for _, lines in ipairs { { "import os", "x = os.path.jo" }, { "from os.path import join", "print(jo" } } do
  if members_at(lines) then
    failures[#failures + 1] = table.concat(lines, " / ") .. ": ordinary code was treated as an import list"
  else
    print("PASS: " .. table.concat(lines, " / ") .. " (not an import list)")
  end
end

vim.fn.delete(file)
if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n"), "\n")
  vim.cmd "cquit 1"
end
vim.cmd "qa!"
