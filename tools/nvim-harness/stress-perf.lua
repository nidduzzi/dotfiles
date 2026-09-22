--- Time the blocking calls in a real project. Over ~100ms is felt as a
--- stutter; over ~500ms reads as a hang.

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

timed("recall.extensions", function()
  return recall.extensions()
end)

timed("recall.top_level_globs", function()
  return recall.top_level_globs()
end)

timed("capabilities.keymaps", function()
  return capabilities.keymaps()
end)

timed("capabilities.commands", function()
  return capabilities.commands()
end)

timed("capabilities.everything", function()
  return capabilities.items("everything")
end)

local ok_agent, agent = pcall(require, "util.agent")
if ok_agent then
  timed("agent.root", function()
    return { agent.root() }
  end)
end

vim.fn.writefile(out, vim.env.NVIM_PERF_OUT or "/tmp/nvim-perf.txt")
