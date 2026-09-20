-- Which keys the capability list claims, and whether anything answers them.
--
-- lua/util/capabilities.lua keeps its list by hand, on purpose: generating it
-- would produce every mapping in the editor, which is the haystack the list
-- exists to avoid. A hand-kept list drifts, and this is the half that can be
-- checked -- the first key of each entry is a global mapping, and either it is
-- bound or the entry is describing something that no longer exists.

local capabilities = require("util.capabilities")

-- In a buffer with a language server attached, because the keys this list
-- describes include the ones Neovim and LazyVim map per buffer on LspAttach.
-- Checked from the dashboard, K reads as unbound -- which says where the
-- check was run, not whether the key works.
vim.cmd.edit(assert(vim.env.CAPABILITY_KEYS_FILE))
vim.wait(8000, function()
  return #vim.lsp.get_clients({ bufnr = 0 }) > 0
end, 200)

---@param key string as written in the capability list
---@return string|nil the leading key, with <leader> resolved
local function first_key(key)
  local first = key:match("^(%S+)")
  if not first then
    return nil
  end
  local leader = vim.g.mapleader == " " and " " or (vim.g.mapleader or "\\")
  return (first:gsub("^<leader>", leader))
end

local out = {}
for _, capability in ipairs(capabilities.features()) do
  local key = first_key(capability.key or "")
  if key then
    local lhs = vim.api.nvim_replace_termcodes(key, true, true, true)
    local bound = vim.fn.maparg(lhs, "n") ~= "" or vim.fn.maparg(lhs, "i") ~= "" or vim.fn.maparg(lhs, "x") ~= ""
    out[#out + 1] = ("%s %s %s"):format(bound and "bound" or "UNBOUND", vim.fn.keytrans(lhs), capability.name)
  end
end

table.sort(out)
vim.fn.writefile(out, assert(vim.env.CAPABILITY_KEYS_OUT))
