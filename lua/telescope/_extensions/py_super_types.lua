local telescope = require("telescope")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

---@diagnostic disable-next-line: unused-local
local M = {}

local defaults = {
  style = "tree",
}

local function py_super_types(opts)
  opts.style = opts.style or defaults.style

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

  local has_ts_utils, ts_utils = pcall(require, "nvim-treesitter.ts_utils")
  if not has_ts_utils then return end

  local original_buf = vim.api.nvim_get_current_buf()

  -- Get enclosing class node
  local function get_enclosing_class_node()
    local node = ts_utils.get_node_at_cursor()
    while node do
      if node:type() == "class_definition" then return node end
      node = node:parent()
    end
    return nil
  end

  -- Get immediate bases
  local function get_bases_with_nodes(class_node)
    local bases = {}
    local bufnr = vim.api.nvim_get_current_buf()
    for child in class_node:iter_children() do
      if child:type() == "argument_list" or child:type() == "base_list" then
        for base in child:iter_children() do
          if base:type() == "identifier" then
            table.insert(bases, { name = vim.treesitter.get_node_text(base, bufnr), node = base })
          end
        end
      end
    end
    return bases
  end

  -- LSP helpers
  local function make_position_params(bufnr, row, col)
    return { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = { line = row, character = col } }
  end

  local function lsp_def_for_node(node, bufnr, callback)
    local row, col = node:start()
    local params = make_position_params(bufnr, row, col)
    vim.lsp.buf_request(bufnr, "textDocument/definition", params, function(err, result)
      if err or not result or vim.tbl_isempty(result) then
        callback(nil)
        return
      end
      callback(result[1] or result)
    end)
  end

  -- Build class tree recursively
  local function build_class_tree(class_node, bufnr, seen, callback)
    seen = seen or {}
    local class_name = vim.treesitter.get_node_text(class_node:child(1), bufnr)
    local key = vim.uri_from_bufnr(bufnr) .. ":" .. class_name
    if seen[key] then
      callback(nil)
      return
    end
    seen[key] = true

    local bases = get_bases_with_nodes(class_node)
    local pending = #bases
    local children = {}

    if pending == 0 then
      callback({ name = class_name, bases = {}, buf = bufnr, node = class_node })
      return
    end

    for _, base in ipairs(bases) do
      lsp_def_for_node(base.node, bufnr, function(loc)
        if loc then
          local fname = vim.uri_to_fname(loc.uri)
          local def_buf = vim.fn.bufnr(fname, true)
          vim.fn.bufload(def_buf)
          local parser = vim.treesitter.get_parser(def_buf)
          local tree = parser:parse()[1]
          local root = tree:root()

          -- Try retrieving a class definition first, if any
          local target_class
          for node in root:iter_children() do
            if node:type() == "class_definition" and node:start() == loc.range.start.line then
              target_class = node
              break
            end
          end

          -- If above does not find a node
          if not target_class then
            -- Find node at LSP location
            target_class = root:named_descendant_for_range(
              loc.range.start.line,
              loc.range.start.character,
              loc.range.start.line,
              loc.range.start.character
            )
            local target_class_orig = target_class

            -- Walk upward until we hit a class_definition
            while target_class do
              if target_class:type() == "class_definition" then
                target_class = target_class
                break
              end
              target_class = target_class:parent()
            end

            -- Or take the found identifier if still not found
            if not target_class then
              if target_class_orig then
                local name = vim.treesitter.get_node_text(target_class_orig, def_buf)

                table.insert(children, {
                  name = name,
                  bases = {},
                  buf = def_buf,
                  node = target_class_orig,
                })

                pending = pending - 1
                if pending == 0 then
                  callback({ name = class_name, bases = children, buf = bufnr, node = class_node })
                end
              end
              return
            end
          end

          if target_class then
            -- Rebuild tree of base classes for each base class
            build_class_tree(target_class, def_buf, seen, function(subtree)
              if subtree then table.insert(children, subtree) end
              pending = pending - 1
              if pending == 0 then
                callback({
                  name = class_name,
                  bases = children,
                  buf = bufnr,
                  node =
                      class_node
                })
              end
            end)
            return
          end
        end
        pending = pending - 1
        if pending == 0 then callback({ name = class_name, bases = children, buf = bufnr, node = class_node }) end
      end)
    end
  end

  -- C3 linearization (Python style)
  local function merge(seqs)
    local result = {}
    while true do
      local non_empty = {}
      for _, seq in ipairs(seqs) do if #seq > 0 then table.insert(non_empty, seq) end end
      if #non_empty == 0 then break end

      local candidate
      for _, seq in ipairs(non_empty) do
        candidate = seq[1]
        local ok = true
        for _, other in ipairs(non_empty) do
          if other ~= seq then
            for i = 2, #other do
              if other[i] == candidate then
                ok = false
                break
              end
            end
          end
          if not ok then break end
        end
        if ok then break end
        candidate = nil
      end
      if not candidate then error("Cannot compute C3 linearization") end
      table.insert(result, candidate)
      for _, seq in ipairs(seqs) do if seq[1] == candidate then table.remove(seq, 1) end end
    end
    return result
  end

  local function linearize(tree)
    if not tree.bases or #tree.bases == 0 then return { tree } end
    local parent_seqs = {}
    for _, b in ipairs(tree.bases) do table.insert(parent_seqs, linearize(b)) end
    table.insert(parent_seqs, vim.tbl_map(function(b) return b end, tree.bases))
    return merge(parent_seqs)
  end

  local function get_depth(cls, target, current_depth)
    current_depth = current_depth or 0
    if cls == target then return current_depth end
    for _, b in ipairs(cls.bases or {}) do
      local d = get_depth(b, target, current_depth + 1)
      if d then return d end
    end
  end

  local function get_display_name(cls, filename, style)
    local relpath = vim.fn.fnamemodify(filename, ":.") -- path relative to cwd

    local start_char = "  "
    if cls.depth == 1 then
      start_char = ""
    elseif cls.is_first then
      start_char = " └─"
    else
      start_char = " ├─"
    end

    if cls.depth >= 3 then
      start_char = " " .. start_char
    end

    local space_count = math.max(0, cls.depth - 2)

    local display
    if style == "flatten" then
      display = cls.name
    elseif style == "relpath" then
      display = string.format("%d %s:%d:%d %s", cls.index, relpath, cls.node:start() + 1, cls.col or 1,
        cls.name)
    else
      display = string.rep(" ·", space_count, " ") ..
          string.format("%s %d %s", start_char, cls.index, cls.name)
    end
    return display
  end

  -- Show in Telescope
  local class_node = get_enclosing_class_node()
  if not class_node then
    vim.notify("No enclosing class found", vim.log.levels.INFO)
    return
  end

  build_class_tree(class_node, original_buf, {}, function(tree)
    if not tree then
      vim.notify("No base classes found", vim.log.levels.INFO)
      return
    end

    local linearized = linearize(tree)
    local entries = {}
    local flatenned = {}

    -- Compute depths for all classes in the linearized list
    local max_depth = 0
    for _, cls in ipairs(linearized) do
      local depth = get_depth(tree, cls) or 1
      cls.depth = depth
      if depth and depth > max_depth then max_depth = depth end
    end

    tree.depths = { max = max_depth }

    -- Compute indices and whether it's the first node at its depth level (for tree drawing)
    local total_nodes = #linearized
    local inspected_nodes = 0
    local curr_depth = 1
    while inspected_nodes < total_nodes do
      local i = 1
      for _, cls in ipairs(linearized) do
        if cls.depth == curr_depth then
          cls.index = inspected_nodes + 1
          if i == 1 then cls.is_first = true end
          inspected_nodes = inspected_nodes + 1
          i = i + 1
          table.insert(flatenned, cls)
        end
      end
      table.insert(tree.depths, {
        depth = curr_depth,
        count = i - 1,
      })
      curr_depth = curr_depth + 1
    end

    if opts.style == "flatten" or opts.style == "relpath" then
      linearized = flatenned
    end

    -- Add display info for Telescope entries
    for _, cls in ipairs(linearized) do
      local filename = vim.uri_to_fname(vim.uri_from_bufnr(cls.buf))

      table.insert(entries, {
        value = cls,
        display = get_display_name(cls, filename, opts.style),
        ordinal = cls.name,
        filename = filename,
        lnum = cls.node:start() + 1,
        col = 1,
      })
    end

    -- Show the picker
    pickers.new({}, {
      prompt_title = string.format("Super Types of %s (%s)", tree.name, opts.style),
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

return telescope.register_extension({
  setup = function(ext_config)
    defaults = vim.tbl_deep_extend("force", defaults, ext_config or {})
  end,

  exports = {
    py_super_types = function(opts)
      opts = vim.tbl_deep_extend("force", defaults, opts or {})
      py_super_types(opts)
    end,
  },
})
