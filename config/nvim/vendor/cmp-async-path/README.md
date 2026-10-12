https://codeberg.org/FelipeLema/cmp-async-path

# cmp-async-path

nvim-cmp source for filesystem paths with async processing (neovim won't block while reading from disk).

forked from https://github.com/hrsh7th/cmp-path/

# Setup

```lua
require'cmp'.setup {
  sources = {
    { name = 'async_path' }
  }
}
```


## Configuration

The below source configuration options are available. To set any of these options, do:

```lua
cmp.setup({
  sources = {
    {
      name = 'async_path',
      option = {
        -- Options go into this table
      },
    },
  },
})
```


### trailing_slash (type: boolean)

_Default:_ `false`

Specify if completed directory names should include a trailing slash. Enabling this option makes this source behave like Vim's built-in path completion.

### label_trailing_slash (type: boolean)

_Default:_ `true`

Specify if directory names in the completion menu should include a trailing slash.

### get_cwd (type: function)

_Default:_ returns the current working directory of the current buffer

Specifies the base directory for relative paths.

### show_hidden_files_by_default (type: boolean)

_Default:_ `false`

Specify if hidden files should appear in the completion menu without the need of typing `.` first.

### Order in completion

You may want to sort the entries coming from this source. Personally, I like the latest entry (file or directory) at the top.

To achieve this ordering, you can _append_ the following config

```lua
require'cmp'.setup {
  -- the rest of the config
  sorting = {
    comparators = vim.list_extend({
    ---@param l cmp.Entry
    ---@param r cmp.Entry
    ---@return boolean|nil
    function(l, r)
      --- Try to compare file/dir entries, give up and delegate if any entry isn't
      ---@param i cmp.Entry
      ---@return uv.fs_stat.result?
      local function stat(i)
        local d = i.completion_item.data or {}
        return (d.stat or d.lstat) or nil
      end
      local ls = stat(l)
      if not ls then
        return nil
      end
      local lr = stat(r)
      if not lr then
        return nil
      end
      return lr.mtime.sec < ls.mtime.sec
    end,
    }, 
    -- ↓ the rest of the default comparators
    require "cmp.config.default"().sorting.comparators)
  }
}

## luatexts

Lua source code for luatexts was embedded. Code originally comes from https://github.com/agladysh/luatexts/
