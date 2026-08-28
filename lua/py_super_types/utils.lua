local M = {}

-- Get enclosing class node
M.get_enclosing_class_node = function()
  local node = vim.treesitter.get_node()
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

local LSP_TIMEOUT_MS = 5000

local function lsp_def_for_node(node, bufnr, callback)
  local row, col = node:start()
  local params = make_position_params(bufnr, row, col)

  local done = false
  local function finish(loc)
    if done then return end
    done = true
    callback(loc)
  end

  local ok, request_ids = pcall(vim.lsp.buf_request, bufnr, "textDocument/definition", params,
    function(err, result)
      if err or not result or vim.tbl_isempty(result) then
        finish(nil)
        return
      end
      finish(result[1] or result)
    end)

  -- No client accepted the request: resolve immediately instead of waiting.
  if not ok or not request_ids or vim.tbl_isempty(request_ids) then
    finish(nil)
    return
  end

  vim.defer_fn(function() finish(nil) end, LSP_TIMEOUT_MS)
end

-- Build the inheritance DAG rooted at class_node
M.build_class_tree = function(class_node, bufnr, callback, registry, ancestors)
  registry = registry or {}
  ancestors = ancestors or {}
  local class_name = vim.treesitter.get_node_text(class_node:child(1), bufnr)
  local key = vim.uri_from_bufnr(bufnr) .. ":" .. class_name

  if ancestors[key] then
    callback(nil) -- cycle: this class is its own ancestor
    return
  end
  if registry[key] then
    callback(registry[key]) -- diamond: reuse the already-built shared node
    return
  end

  -- Register before resolving bases so diamonds/cycles observe this node
  local node = { name = class_name, bases = {}, buf = bufnr, node = class_node }
  registry[key] = node

  local child_ancestors = {}
  for k, v in pairs(ancestors) do child_ancestors[k] = v end
  child_ancestors[key] = true

  local bases = get_bases_with_nodes(class_node)
  local pending = #bases

  if pending == 0 then
    callback(node)
    return
  end

  for _, base in ipairs(bases) do
    lsp_def_for_node(base.node, bufnr, function(loc)
      local function done()
        pending = pending - 1
        if pending == 0 then callback(node) end
      end

      if not loc then
        done()
        return
      end

      local fname = vim.uri_to_fname(loc.uri)
      local def_buf = vim.fn.bufnr(fname, true)
      vim.fn.bufload(def_buf)
      local parser = vim.treesitter.get_parser(def_buf)
      local tree = parser:parse()[1]
      local root = tree:root()

      -- Try retrieving a class definition first, if any
      local target_class
      for n in root:iter_children() do
        if n:type() == "class_definition" and n:start() == loc.range.start.line then
          target_class = n
          break
        end
      end

      -- If above does not find a node
      if not target_class then
        -- Find node at LSP location
        local located = root:named_descendant_for_range(
          loc.range.start.line,
          loc.range.start.character,
          loc.range.start.line,
          loc.range.start.character
        )

        -- Walk upward until we hit a class_definition
        target_class = located
        while target_class do
          if target_class:type() == "class_definition" then break end
          target_class = target_class:parent()
        end

        -- Or take the found identifier as a leaf if still not a class
        if not target_class then
          if located then
            table.insert(node.bases, {
              name = vim.treesitter.get_node_text(located, def_buf),
              bases = {},
              buf = def_buf,
              node = located,
            })
          end
          done()
          return
        end
      end

      -- Rebuild tree of base classes for each base class
      M.build_class_tree(target_class, def_buf, function(subtree)
        if subtree then table.insert(node.bases, subtree) end
        done()
      end, registry, child_ancestors)
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

local function c3(node, cache)
  cache = cache or {}
  if cache[node] then return cache[node] end

  local result
  if not node.bases or #node.bases == 0 then
    result = { node }
  else
    local seqs = {}
    for _, b in ipairs(node.bases) do
      local lb = c3(b, cache)
      local copy = {}
      for i = 1, #lb do copy[i] = lb[i] end
      table.insert(seqs, copy)
    end
    local direct = {}
    for i = 1, #node.bases do direct[i] = node.bases[i] end
    table.insert(seqs, direct)
    result = merge(seqs)
    table.insert(result, 1, node)
  end

  cache[node] = result
  return result
end

M.linearize = function(tree)
  return c3(tree)
end

M.get_depth = function(cls, target, current_depth)
  current_depth = current_depth or 0
  if cls == target then return current_depth end
  for _, b in ipairs(cls.bases or {}) do
    local d = M.get_depth(b, target, current_depth + 1)
    if d then return d end
  end
end

-- Walk the actual base edges depth-first and produce ordered lines, each with a
-- precomputed connector prefix, for the "tree" style. The current class is the
-- root (no connector); its bases nest beneath it. A child with a following
-- sibling gets "├─" plus a "│" continuation guide; a last child that is a leaf
-- gets "└─"; a last child that still has bases of its own gets the downward
-- corner "┌─" that opens toward the base nested below it. Diamonds are shown
-- under each parent.
M.tree_lines = function(root)
  local lines = {}

  local function visit(node, prefix, connector)
    lines[#lines + 1] = { node = node, prefix = prefix .. connector }

    local child_prefix
    if connector == "" then
      child_prefix = prefix -- root: children align directly beneath
    elseif connector == "├─ " then
      child_prefix = prefix .. "│  " -- more siblings follow: keep the guide
    else
      child_prefix = prefix .. "   " -- last child: nothing continues at this level
    end

    local bases = node.bases or {}
    for i, b in ipairs(bases) do
      local child_connector
      if i < #bases then
        child_connector = "├─ "
      elseif b.bases and #b.bases > 0 then
        child_connector = "┌─ "
      else
        child_connector = "└─ "
      end
      visit(b, child_prefix, child_connector)
    end
  end

  visit(root, "", "")
  return lines
end

return M
