-- What one press of the dismiss key closes, with things open on top of things.
-- See DECISIONS 31 and 32: every feature passed alone, the holes were all
-- combinations (a debugger UI of six windows, a diff view owning its tab).
--
-- Writes one line per case to $DISMISS_OUT:
--   <case> opened=<what was on screen> after=<what is left>

local dismiss = require("util.dismiss")

--- What is on screen, ignoring notifications (transient, unasked-for, and
--- already handled by the dismiss key on the rung below the panels).
---@return string
local function windows()
  local names = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local filetype = vim.bo[buf].filetype
    if not filetype:match("^snacks_notif") then
      names[#names + 1] = filetype ~= "" and filetype or (vim.bo[buf].buftype ~= "" and vim.bo[buf].buftype or "file")
    end
  end
  table.sort(names)
  return table.concat(names, ",")
end

---@param was string
---@param timeout integer
local function until_different(was, timeout)
  vim.wait(timeout, function()
    return windows() ~= was
  end, 100)
end

---@param name string
---@param open fun()
---@return string
local function case(name, open)
  pcall(function()
    Snacks.notifier.hide()
  end)
  vim.wait(300)

  local before = windows()
  open()
  until_different(before, 15000)
  local opened = windows()

  dismiss.dismiss()
  until_different(opened, 8000)

  return ("%s opened=%s after=%s"):format(name, opened, windows())
end

vim.cmd.edit(assert(vim.env.DISMISS_FILE))
vim.wait(3000)

local out = { "start " .. windows() }

out[#out + 1] = case("picker", function()
  Snacks.picker.files()
end)

out[#out + 1] = case("explorer", function()
  Snacks.explorer()
end)

out[#out + 1] = case("terminal", function()
  Snacks.terminal()
end)

out[#out + 1] = case("trouble", function()
  vim.diagnostic.set(vim.api.nvim_create_namespace("dismiss-combinations"), 0, {
    {
      lnum = 0,
      col = 0,
      message = "something to list",
      severity = vim.diagnostic.severity.WARN,
    },
  })
  vim.cmd("Trouble diagnostics open")
end)

out[#out + 1] = case("quickfix", function()
  vim.fn.setqflist({ { filename = vim.api.nvim_buf_get_name(0), lnum = 1, text = "something" } })
  vim.cmd("copen")
end)

out[#out + 1] = case("grug-far", function()
  vim.cmd("GrugFar")
end)

out[#out + 1] = case("diff view", function()
  vim.cmd("DiffviewOpen")
end)

out[#out + 1] = case("debugger", function()
  require("lazy").load({ plugins = { "nvim-dap-ui" } })
  pcall(function()
    require("dapui").open()
  end)
end)

out[#out + 1] = "end " .. windows()

vim.fn.writefile(out, assert(vim.env.DISMISS_OUT))
