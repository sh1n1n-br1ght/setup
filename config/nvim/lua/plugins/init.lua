return {
  {
    "https://codeberg.org/FelipeLema/cmp-async-path.git",
    dir = vim.fn.stdpath "config" .. "/vendor/cmp-async-path",
  },
  {
    "stevearc/conform.nvim",
    -- event = 'BufWritePre', -- uncomment for format on save
    opts = require "configs.conform",
  },
  {
    "hrsh7th/nvim-cmp",
    opts = function(_, opts)
      return require("configs.python_imports").setup(opts)
    end,
  },

  -- These are some examples, uncomment them if you want to see them work!
  {
    "neovim/nvim-lspconfig",
    config = function()
      require "configs.lspconfig"
    end,
  },

  {
    "windwp/nvim-autopairs",
    config = function(_, opts)
      require("configs.autopairs").setup(opts)
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    opts = function()
      return {
        ensure_installed = { "lua", "luadoc", "printf", "vim", "vimdoc", "python", "bash", "json", "toml", "html", "css" },
      }
    end,
  },

  -- test new blink
  -- { import = "nvchad.blink.lazyspec" },

  -- {
  -- 	"nvim-treesitter/nvim-treesitter",
  -- 	opts = {
  -- 		ensure_installed = {
  -- 			"vim", "lua", "vimdoc",
  --      "html", "css"
  -- 		},
  -- 	},
  -- },
}
