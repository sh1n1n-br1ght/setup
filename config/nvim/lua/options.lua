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

-- Draw the cursor in the theme's cursor colors (the Cursor highlight). Without a highlight
-- group the terminal's own cursor color is used, and a white one vanishes on a light theme.
-- Neovim hands the terminal its own color back on exit.
vim.o.guicursor = "n-v-c-sm:block-Cursor,i-ci-ve:ver25-Cursor,r-cr-o:hor20-Cursor,t:block-blinkon500-blinkoff500-TermCursor"

-- local o = vim.o
-- o.cursorlineopt ='both' -- to enable cursorline!
