local telescope = require("telescope")
local py_super_types = require("py_super_types")

local M = {}

M.config = {}

return telescope.register_extension({
  setup = function(ext_config, config)
    M.config = vim.tbl_deep_extend("force", {}, py_super_types.plugin.config, ext_config or {})
  end,

  exports = {
    py_super_types = function(opts)
      opts = vim.tbl_deep_extend("force", {}, M.config, opts or {})
      return py_super_types.plugin.py_super_types(opts)
    end,
  },
})
