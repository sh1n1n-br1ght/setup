-- Completion inside `from module import ...` lists shows only that module's members.
--
-- pyrefly lists a module's members correctly for the first imported name and whenever a
-- letter has been typed. With nothing typed after a comma, though, it returns the file's
-- general scope (builtins, other imports, keywords), and inside parentheses it returns
-- nothing; nvim-cmp then keeps filtering that list as you type. So in import lists this
-- source asks pyrefly at the first imported name, where the answer is always the module's
-- full member list, and the other sources are hidden.
local M = {}

local cache = {}

-- The 0-based row and byte column where pyrefly lists the members of the module whose
-- import list holds the cursor, or nil when the cursor is not in such a list.
function M.anchor()
  if vim.bo.filetype ~= "python" then
    return nil
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local key = table.concat({ vim.api.nvim_get_current_buf(), vim.b.changedtick, row, col }, ":")
  if cache.key == key then
    return cache.value
  end
  cache = { key = key }

  local top = math.max(0, row - 50)
  local lines = vim.api.nvim_buf_get_lines(0, top, row + 1, false)
  lines[#lines] = lines[#lines]:sub(1, col)
  for i = #lines, 1, -1 do
    local after_import = lines[i]:match "^%s*from%s+[%w_.]+%s+import()[%s(]"
    if after_import then
      local text = table.concat(lines, "\n", i)
      local rest = text:sub(after_import)
      local parenthesized = rest:match "^%s*%(" ~= nil
      local names_at = after_import + #rest:match "^%s*%(?" -- start of the names, 1-based in text
      local names = text:sub(names_at)
      -- A plain import ends with its line, a parenthesized one at ")".
      if (parenthesized and names:find(")", 1, true)) or (not parenthesized and i ~= #lines) then
        return nil
      end
      local value = { row, col }
      local first = names_at + #names:match "^%s*"
      if names:find(",", 1, true) and text:sub(first, first):match "[%a_]" then
        -- Just after the first letter of the first name; the typed word filters the list.
        local before = text:sub(1, first)
        local _, breaks = before:gsub("\n", "")
        value = { top + i - 1 + breaks, #before:match "[^\n]*$" }
      end
      cache.value = value
      return value
    end
    -- An earlier line can only start the import if the list is parenthesized and still open.
    if lines[i]:find(")", 1, true) and i < #lines then
      return nil
    end
  end
  return nil
end

local function pyrefly()
  return vim.lsp.get_clients({ bufnr = 0, name = "pyrefly" })[1]
end

local source = {}

function source:get_debug_name()
  return "python_imports"
end

function source:is_available()
  return vim.bo.filetype == "python" and pyrefly() ~= nil
end

function source:complete(_, callback)
  local anchor, client = M.anchor(), pyrefly()
  if not anchor or not client then
    return callback()
  end
  local line = vim.api.nvim_buf_get_lines(0, anchor[1], anchor[1] + 1, false)[1] or ""
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = anchor[1], character = vim.str_utfindex(line, client.offset_encoding, anchor[2], false) },
    context = { triggerKind = 1 },
  }
  client:request("textDocument/completion", params, function(err, result)
    if err or not result then
      return callback()
    end
    local items = result.items or result
    for _, item in ipairs(items) do
      -- Edits would point at the first name rather than at the cursor.
      item.textEdit, item.additionalTextEdits = nil, nil
    end
    callback { items = items, isIncomplete = false }
  end, 0)
end

function source:resolve(item, callback)
  local client = pyrefly()
  if not client then
    return callback(item)
  end
  client:request("completionItem/resolve", item, function(err, resolved)
    callback(not err and resolved or item)
  end, 0)
end

-- Adds the source to NvChad's nvim-cmp options and hides the others in import lists.
function M.setup(opts)
  if not M.registered then
    require("cmp").register_source("python_imports", setmetatable({}, { __index = source }))
    M.registered = true
  end
  local function outside_import_list()
    return not (M.anchor() and pyrefly())
  end
  for _, entry in ipairs(opts.sources) do
    entry.entry_filter = outside_import_list
  end
  table.insert(opts.sources, 1, { name = "python_imports" })
  return opts
end

return M
