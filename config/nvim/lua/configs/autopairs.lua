local M = {}

local function in_python_import()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local ok, node = pcall(function()
    local parser = vim.treesitter.get_parser(0, "python")
    parser:parse { row - 1, row }
    return vim.treesitter.get_node { pos = { row - 1, math.max(col - 1, 0) } }
  end)

  while ok and node do
    local kind = node:type()
    if kind == "import_statement" or kind == "import_from_statement" then
      return true
    end
    if kind == "ERROR" and vim.treesitter.get_node_text(node, 0):match "^%s*from%s+%S+%s+import%s*%(" then
      return true
    end
    node = node:parent()
  end

  local statement = vim.api.nvim_get_current_line():sub(1, col):match "[^;]*$"
  return statement:match "^%s*from%s+" ~= nil or statement:match "^%s*import%s+" ~= nil
end

function M.setup(opts)
  require("nvim-autopairs").setup(opts)

  local on_confirm_done = require("nvim-autopairs.completion.cmp").on_confirm_done()
  require("cmp").event:on("confirm_done", function(event)
    if vim.bo.filetype == "python" and in_python_import() then
      return
    end
    on_confirm_done(event)
  end)
end

return M
