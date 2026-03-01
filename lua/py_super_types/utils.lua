local ts_utils = require("nvim-treesitter.ts_utils")

local M = {}

-- Get enclosing class node
M.get_enclosing_class_node = function()
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
M.build_class_tree = function(class_node, bufnr, seen, callback)
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
          M.build_class_tree(target_class, def_buf, seen, function(subtree)
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

M.linearize = function(tree)
  if not tree.bases or #tree.bases == 0 then return { tree } end
  local parent_seqs = {}
  for _, b in ipairs(tree.bases) do table.insert(parent_seqs, M.linearize(b)) end
  table.insert(parent_seqs, vim.tbl_map(function(b) return b end, tree.bases))
  return merge(parent_seqs)
end

M.get_depth = function(cls, target, current_depth)
  current_depth = current_depth or 0
  if cls == target then return current_depth end
  for _, b in ipairs(cls.bases or {}) do
    local d = M.get_depth(b, target, current_depth + 1)
    if d then return d end
  end
end

M.get_display_name = function(cls, filename, style)
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

return M
