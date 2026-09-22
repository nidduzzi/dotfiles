-- Report what this configuration does to the picker's keys, to $PICKER_KEYS_OUT:
--   override <window> <key> <snacks action> -> <ours>
--   bound    <window> <key>

local defaults = require("snacks.picker.config.defaults").defaults
local resolved = require("snacks.picker.config").get({ source = vim.env.PICKER_KEYS_SOURCE or "grep" })

---@param spec any
---@return string
local function action_of(spec)
  if type(spec) == "string" then
    return spec
  end
  if type(spec) == "table" then
    local first = spec[1]
    if type(first) == "table" then
      return table.concat(first, "+")
    end
    return tostring(first)
  end
  return tostring(spec)
end

local out = {}
for window, config in pairs(resolved.win or {}) do
  local theirs = vim.tbl_get(defaults, "win", window, "keys") or {}
  for key, spec in pairs(config.keys or {}) do
    out[#out + 1] = ("bound %s %s"):format(window, key)
    local was = theirs[key]
    if was ~= nil and action_of(was) ~= action_of(spec) then
      out[#out + 1] = ("override %s %s %s -> %s"):format(window, key, action_of(was), action_of(spec))
    end
  end
end

table.sort(out)
local out_path = assert(vim.env.PICKER_KEYS_OUT, "PICKER_KEYS_OUT is not set")
vim.fn.writefile(out, out_path)
