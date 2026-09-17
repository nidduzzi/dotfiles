--- Dump every mapping as JSON, so two configurations can be compared.
---
--- Written for the collision check: the same dump is taken from stock LazyVim
--- and from this configuration, and the difference is every key this config
--- took over, added or lost. Finding those by hand is how <leader>sD ended up
--- replacing workspace diagnostics and <leader>cA ended up losing to Source
--- Action, both noticed only after they shipped.
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
        -- The right hand side distinguishes two mappings that share a
        -- description, and shows what a key was before it was taken over.
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
