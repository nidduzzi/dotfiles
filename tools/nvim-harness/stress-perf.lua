--- Time the things that run while someone is waiting.
---
--- The stress probe asks whether a feature works in a real project. This asks
--- how long it blocks the editor, which is a different question with a
--- different answer: a filesystem walk that is instant over a fixture can take
--- a second over a repository with five thousand files, and it runs on the main
--- loop, so a second is a second of frozen editor.
---
--- Anything over about 100ms here is felt as a stutter; over 500ms reads as a
--- hang.

local out = {}

---@param name string
---@param fn fun(): any
local function timed(name, fn)
  local t0 = vim.uv.hrtime()
  local ok, result = pcall(fn)
  local ms = (vim.uv.hrtime() - t0) / 1e6

  local detail = ""
  if ok and type(result) == "table" then
    detail = ("%d items"):format(#result)
  elseif not ok then
    detail = "ERROR " .. tostring(result):sub(1, 80)
  end

  table.insert(out, ("%-28s %8.1fms  %s"):format(name, ms, detail))
end

table.insert(out, ("project: %s"):format(vim.fn.fnamemodify(assert(vim.uv.cwd()), ":t")))
local tracked = vim.fn.systemlist({ "git", "ls-files" })
table.insert(out, ("tracked: %d"):format(vim.v.shell_error == 0 and #tracked or 0))

local recall = require("util.recall")
local capabilities = require("util.capabilities")

-- Called on every <a-e> inside a grep, to suggest extensions.
timed("recall.extensions", function()
  return recall.extensions()
end)

-- Called on every <a-G>, to suggest path globs.
timed("recall.top_level_globs", function()
  return recall.top_level_globs()
end)

-- Called every time the capability picker opens.
timed("capabilities.keymaps", function()
  return capabilities.keymaps()
end)

timed("capabilities.commands", function()
  return capabilities.commands()
end)

timed("capabilities.everything", function()
  return capabilities.items("everything")
end)

-- The agent's idea of where it is, called once per request.
local ok_agent, agent = pcall(require, "util.agent")
if ok_agent then
  timed("agent.root", function()
    return { agent.root() }
  end)
end

vim.fn.writefile(out, vim.env.NVIM_PERF_OUT or "/tmp/nvim-perf.txt")
