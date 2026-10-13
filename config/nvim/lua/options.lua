require "nvchad.options"

-- add yours here!

-- Python brackets the way black and ruff format them: contents one level in, and the
-- closing bracket back under the line that opened it (Neovim's defaults use two levels
-- and line the bracket up with the contents).
vim.g.python_indent = {
  open_paren = "shiftwidth()",
  continue = "shiftwidth()",
  closed_paren_align_last_line = false,
}

-- local o = vim.o
-- o.cursorlineopt ='both' -- to enable cursorline!
