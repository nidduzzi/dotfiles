--- Audit every multi-key mapping: which exist, which are dead, which describe
--- themselves with machinery rather than words.
---
--- Run with a file open, so buffer-local mappings and attached servers are
--- real:
---   nvim --headless -c 'luafile keymap-audit.lua' -c qa
---
--- Writes a report to $NVIM_KEYMAP_AUDIT, or prints it.

local report = {}

local function line(text)
  table.insert(report, text or "")
end

---@param map table
---@return string status, string text
local function describe(map)
  local desc = map.desc or ""

  if desc == "" then
    local rhs = map.rhs or ""
    if rhs == "" then
      return "no description", "<lua callback>"
    end
    return "no description", rhs
  end

  if desc:match("^[%w_%.]+%(%)?$") or desc:match("^function") or desc:match("^<Lua") then
    return "names code", desc
  end

  return "ok", desc
end

--- `prefixes` holds every mapping that starts a longer one -- a group like
--- <leader>s is what makes the hints appear, not a dead end.
---@param map table
---@param prefixes table<string, boolean>
---@return string
local function liveness(map, prefixes)
  local rhs = map.rhs or ""

  if rhs == "" then
    if map.callback then
      return "callback"
    end
    return prefixes[vim.fn.keytrans(map.lhs or "")] and "prefix" or "EMPTY"
  end

  local command = rhs:match("^[<:]?[Cc][Mm][Dd]?>?:?(%a[%w_]*)") or rhs:match("^:(%a[%w_]*)")
  if command then
    if vim.fn.exists(":" .. command) == 0 then
      return "DEAD: no :" .. command
    end
    return "command"
  end

  return "keys"
end

--- Single-key mappings, collected across every call: invisible to which-key
--- (needs a prefix to pop up on) and to the combination audit alike.
---@type table[]
local singles = {}

---@param mode string
---@return table[]
local function collect(mode)
  local rows = {}

  local prefixes = {}
  local function note_prefixes(maps)
    for _, map in ipairs(maps) do
      local lhs = vim.fn.keytrans(map.lhs or "")
      for length = 1, vim.fn.strchars(lhs) - 1 do
        prefixes[vim.fn.strcharpart(lhs, 0, length)] = true
      end
    end
  end
  note_prefixes(vim.api.nvim_get_keymap(mode))
  note_prefixes(vim.api.nvim_buf_get_keymap(0, mode))

  local function add(maps, scope)
    for _, map in ipairs(maps) do
      local lhs = vim.fn.keytrans(map.lhs or "")
      -- Single keys are not combinations. flash.nvim takes over f/F/t/T this
      -- way, so these are collected rather than skipped.
      if vim.fn.strchars(lhs) == 1 then
        local status, text = describe(map)
        table.insert(singles, {
          lhs = lhs,
          mode = mode,
          scope = scope,
          status = status,
          desc = text,
        })
      elseif vim.fn.strchars(lhs) > 1 then
        local status, text = describe(map)
        table.insert(rows, {
          lhs = lhs,
          mode = mode,
          scope = scope,
          status = status,
          desc = text,
          live = liveness(map, prefixes),
        })
      end
    end
  end

  add(vim.api.nvim_get_keymap(mode), "global")
  add(vim.api.nvim_buf_get_keymap(0, mode), "buffer")

  return rows
end

---@return table[]
local function taken_over()
  local interesting = {}
  for _, row in ipairs(singles) do
    if row.scope == "global" and row.status ~= "ok" then
      table.insert(interesting, row)
    end
  end

  table.sort(interesting, function(a, b)
    if a.lhs == b.lhs then
      return a.mode < b.mode
    end
    return a.lhs < b.lhs
  end)

  return interesting
end

local context = vim.env.NVIM_KEYMAP_AUDIT_CONTEXT or vim.bo.filetype
line("# Keymap audit")
line()
line(("context: %s   file: %s"):format(context, vim.fn.expand("%:t")))

local clients = vim.lsp.get_clients({ bufnr = 0 })
local methods = {}
for _, client in ipairs(clients) do
  for method, supported in pairs(client.server_capabilities or {}) do
    if supported then
      methods[method] = true
    end
  end
end

line()
line("## language servers")
if #clients == 0 then
  line("none attached")
else
  for _, client in ipairs(clients) do
    local caps = client.server_capabilities or {}
    line(("%s: hover=%s definition=%s references=%s rename=%s codeAction=%s signature=%s"):format(
      client.name,
      tostring(caps.hoverProvider ~= nil and caps.hoverProvider ~= false),
      tostring(caps.definitionProvider ~= nil and caps.definitionProvider ~= false),
      tostring(caps.referencesProvider ~= nil and caps.referencesProvider ~= false),
      tostring(caps.renameProvider ~= nil and caps.renameProvider ~= false),
      tostring(caps.codeActionProvider ~= nil and caps.codeActionProvider ~= false),
      tostring(caps.signatureHelpProvider ~= nil and caps.signatureHelpProvider ~= false)
    ))
  end
end

local all = {}
for _, mode in ipairs({ "n", "i", "x", "o", "c", "t" }) do
  vim.list_extend(all, collect(mode))
end

table.sort(all, function(a, b)
  if a.lhs == b.lhs then
    return a.mode < b.mode
  end
  return a.lhs < b.lhs
end)

local problems = {}
for _, row in ipairs(all) do
  if row.status ~= "ok" or row.live:match("^DEAD") or row.live == "EMPTY" then
    table.insert(problems, row)
  end
end

line()
line(("## totals: %d combinations, %d with a problem"):format(#all, #problems))

line()
line("## problems")
if #problems == 0 then
  line("none")
else
  for _, row in ipairs(problems) do
    line(("%-22s %-2s %-7s %-14s %s"):format(row.lhs, row.mode, row.scope, row.status, row.live))
  end
end

local replaced = taken_over()
line()
line(("## single keys taken over: %d"):format(#replaced))
if #replaced == 0 then
  line("none")
else
  for _, row in ipairs(replaced) do
    line(("TAKEN %-4s %-2s %-7s %-14s %s"):format(row.lhs, row.mode, row.scope, row.status, row.desc))
  end
end

line()
line("## every combination")
for _, row in ipairs(all) do
  line(("%-22s %-2s %-7s %-9s %s"):format(row.lhs, row.mode, row.scope, row.live, row.desc))
end

local out = vim.env.NVIM_KEYMAP_AUDIT
if out and out ~= "" then
  vim.fn.writefile(report, out)
else
  print(table.concat(report, "\n"))
end
