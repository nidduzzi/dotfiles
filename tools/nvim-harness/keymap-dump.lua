--- Dump every mapping as JSON, for the collision check (diffed against a
--- stock LazyVim dump to find what this config took over, added or lost).
---
--- Set NVIM_KEYMAP_DUMP to the output path.

local dump = {}

for _, mode in ipairs({ "n", "i", "x", "o", "c", "t" }) do
  local function record(maps, scope)
    for _, map in ipairs(maps) do
      local lhs = vim.fn.keytrans(map.lhs or "")
      table.insert(dump, {
        lhs = lhs,
        mode = mode,
        scope = scope,
        desc = map.desc or "",
        rhs = map.rhs or (map.callback and "<callback>" or ""),
      })
    end
  end

  record(vim.api.nvim_get_keymap(mode), "global")
  record(vim.api.nvim_buf_get_keymap(0, mode), "buffer")
end

table.sort(dump, function(a, b)
  if a.lhs == b.lhs then
    return a.mode < b.mode
  end
  return a.lhs < b.lhs
end)

local out = vim.env.NVIM_KEYMAP_DUMP or "/tmp/keymap-dump.json"
vim.fn.writefile({ vim.json.encode(dump) }, out)
