--- Audit every multi-key mapping: what it is, where it applies, whether it works.
---
--- Three questions this answers, which reading the config cannot:
---
---   * which combinations exist, in which mode, in which context
---   * which of them show up in the hints but do nothing when pressed
---   * which of them describe themselves with machinery rather than words
---
--- Run it through the harness with a file open, so buffer-local mappings and
--- attached language servers are real:
---
---   nvim --headless -c 'luafile keymap-audit.lua' -c qa
---
--- It writes a report to the path in $NVIM_KEYMAP_AUDIT, or prints it.

local report = {}

local function line(text)
  table.insert(report, text or "")
end

--- Does this mapping describe itself in words a person would use?
---@param map table
---@return string status, string text
local function describe(map)
  local desc = map.desc or ""

  if desc == "" then
    local rhs = map.rhs or ""
    if rhs == "" then
      -- A Lua callback with no description: the hint shows the function.
      return "no description", "<lua callback>"
    end
    return "no description", rhs
  end

  -- A description that is really a function name or a Lua path, which is what
  -- a plugin leaves behind when it forgets to write one.
  if desc:match("^[%w_%.]+%(%)?$") or desc:match("^function") or desc:match("^<Lua") then
    return "names code", desc
  end

  return "ok", desc
end

--- Is there anything on the other end of this mapping?
---
--- `prefixes` holds every mapping that is the start of a longer one, because a
--- group like <leader>s is registered as a mapping with nothing behind it and
--- is not dead: it is the thing that makes the hints appear.
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

  -- <cmd>Foo<cr> is dead if :Foo does not exist.
  local command = rhs:match("^[<:]?[Cc][Mm][Dd]?>?:?(%a[%w_]*)") or rhs:match("^:(%a[%w_]*)")
  if command then
    if vim.fn.exists(":" .. command) == 0 then
      return "DEAD: no :" .. command
    end
    return "command"
  end

  return "keys"
end

--- Single-key mappings, collected across every call so they can be reported
--- on their own. A plugin that takes over `t` is invisible to which-key and to
--- the combination audit alike.
---@type table[]
local singles = {}

--- Every mapping of two keys or more, in one mode, global and buffer-local.
---@param mode string
---@return table[]
local function collect(mode)
  local rows = {}

  -- Anything that another mapping extends is a prefix, not a dead end.
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
      -- Single keys are not combinations, and which-key has nothing to show
      -- for them because there is no prefix to wait on. They are collected
      -- separately rather than skipped: a plugin that takes over a built-in
      -- single key and gives it no description is the hardest kind of key to
      -- find out about. flash.nvim takes f, F, t and T this way, and "what
      -- does t do" had no answer anywhere in the editor.
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

--- Single keys whose behaviour was replaced, worst first: the ones that cannot
--- say what they do.
---@return table[]
local function taken_over()
  -- Vim's own single-key commands have no desc either, and listing all of them
  -- would bury the handful a plugin actually replaced. A global mapping with a
  -- callback is a plugin's doing; a plain rhs is usually a personal remap and
  -- reads for itself.
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

-- What the attached servers can actually do. LazyVim binds its LSP keys only
-- when a client supports the method, so a key that is bound and unsupported is
-- worth seeing; so is a key that is missing because nothing supports it.
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
line("-- A built-in key a plugin replaced without saying what it now does.")
line("-- Invisible to which-key, which needs a prefix to pop up on.")
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
