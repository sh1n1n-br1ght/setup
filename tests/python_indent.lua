-- Checks Python bracket indentation (options.lua): contents one level in, and the closing
-- bracket under the start of the line that opened it.
--   nvim --headless -c 'lua dofile("tests/python_indent.lua")'
-- Each line is typed after `o`, so indentation is computed as while editing.
local typed = {
  { "def handler():", 0 },
  { "builder.row(", 4 },
  { "a,", 8 },
  { ")", 4 },
  { "x = foo(bar(", 4 },
  { "1", 8 },
  { "))", 4 },
  { "items = [", 4 },
  { "1,", 8 },
  { "]", 4 },
  { "done = True", 4 },
}
vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
vim.bo.filetype = "python"
for number, line in ipairs(typed) do
  vim.cmd("normal! " .. (number == 1 and "i" or "o") .. line[1])
end
local failures = {}
for number, line in ipairs(typed) do
  local got = vim.fn.indent(number)
  if got ~= line[2] then
    failures[#failures + 1] = string.format("line %d %q: indent %d, expected %d", number, line[1], got, line[2])
  end
end
if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n"), "\n")
  vim.cmd "cquit 1"
end
print "PASS: Python brackets indent one level and close under the line that opened them"
vim.cmd "qa!"
