local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local actions = require("telescope.actions")
local conf = require("telescope.config").values
local previewers = require("telescope.previewers")
local action_state = require("telescope.actions.state")
local utils = require("py_super_types.utils")

local M = {}

M.config = {
  style = "tree",
}

M.py_super_types = function(opts)
  opts = opts or M.config

  local allowed_styles = {
    tree = true,
    flatten = true,
    relpath = true,
  }

  if not allowed_styles[opts.style] then
    vim.notify(
      "Invalid style. Use: tree (default) | flatten | relpath",
      vim.log.levels.ERROR
    )
    return
  end


  local original_buf = vim.api.nvim_get_current_buf()

  -- Show in Telescope
  local class_node = utils.get_enclosing_class_node()
  if not class_node then
    vim.notify("No enclosing class found", vim.log.levels.INFO)
    return
  end

  utils.build_class_tree(class_node, original_buf, function(tree)
    if not tree then
      vim.notify("No base classes found", vim.log.levels.INFO)
      return
    end

    local linearized = utils.linearize(tree)
    local entries = {}
    local flatenned = {}

    -- Compute depths for all classes in the linearized list
    local max_depth = 0
    for _, cls in ipairs(linearized) do
      local depth = (utils.get_depth(tree, cls) or 0) + 1
      cls.depth = depth
      if depth > max_depth then max_depth = depth end
    end

    tree.depths = { max = max_depth }

    -- Group into depth order and assign indices (used by flatten/relpath styles)
    local total_nodes = #linearized
    local inspected_nodes = 0
    local curr_depth = 1
    while inspected_nodes < total_nodes do
      local count = 0
      for _, cls in ipairs(linearized) do
        if cls.depth == curr_depth then
          cls.index = inspected_nodes + 1
          inspected_nodes = inspected_nodes + 1
          count = count + 1
          table.insert(flatenned, cls)
        end
      end
      table.insert(tree.depths, {
        depth = curr_depth,
        count = count,
      })
      curr_depth = curr_depth + 1
    end

    -- Assemble the display items
    local items = {}
    if opts.style == "tree" then
      for i, line in ipairs(utils.tree_lines(tree)) do
        items[i] = { node = line.node, index = i, prefix = line.prefix }
      end
    else
      for i, cls in ipairs(flatenned) do
        items[i] = { node = cls, index = cls.index or i }
      end
    end

    -- Add display info for Telescope entries
    for _, item in ipairs(items) do
      local cls = item.node
      local filename = vim.uri_to_fname(vim.uri_from_bufnr(cls.buf))
      local lnum = cls.node:start() + 1

      local display
      if opts.style == "flatten" then
        display = cls.name
      elseif opts.style == "relpath" then
        local relpath = vim.fn.fnamemodify(filename, ":.")
        display = string.format("%d %s:%d:%d %s", item.index, relpath, lnum, 1, cls.name)
      else
        display = string.format("%s%d %s", item.prefix or "", item.index, cls.name)
      end

      table.insert(entries, {
        value = { name = cls.name, node = cls.node, buf = cls.buf },
        display = display,
        ordinal = cls.name,
        filename = filename,
        lnum = lnum,
        col = 1,
      })
    end

    -- Show the picker
    pickers.new({}, {
      prompt_title = string.format("Super Types of %s (%s)", tree.name, opts.style),
      sorting_strategy = "ascending",
      finder = finders.new_table {
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry.value,
            display = entry.display,
            ordinal = entry.ordinal,
            filename = entry.filename,
            lnum = entry.lnum,
            col = entry.col,
          }
        end
      },
      sorter = conf.generic_sorter({}),
      previewer = previewers.vim_buffer_vimgrep.new({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          vim.cmd("edit " .. selection.filename)
          vim.api.nvim_win_set_cursor(0, { selection.lnum, selection.col })
        end)
        return true
      end,
    }):find()
  end)
end

return M
