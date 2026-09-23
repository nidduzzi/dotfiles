--- Measure this configuration against a real project, from inside it: does
--- it hold up in a repository with thousands of files, vendored code and a
--- language nobody tested against.
---
--- Writes one line per measurement to $NVIM_STRESS_OUT.

local out = {}

---@param key string
---@param value any
local function say(key, value)
  table.insert(out, ("%-28s %s"):format(key, tostring(value)))
end

local started = vim.uv.hrtime()

say("project", vim.fn.fnamemodify(vim.uv.cwd(), ":t"))
say("filetype", vim.bo.filetype ~= "" and vim.bo.filetype or "none")

-- A list, not a string: 'shell' quotes differently on Windows and needs
-- 2>/dev/null to exist at all.
local tracked = vim.fn.systemlist({ "git", "ls-files" })
if vim.v.shell_error ~= 0 then
  tracked = {}
end
say("tracked_files", #tracked)

local all = vim.fs.find(function(name, path)
  return not path:match("/%.git/")
end, { path = assert(vim.uv.cwd()), type = "file", limit = 60000 })
say("files_on_disk", #all)

local ok, capabilities = pcall(require, "util.capabilities")
if ok then
  local t0 = vim.uv.hrtime()
  local keymaps = capabilities.keymaps()
  local keymap_ms = (vim.uv.hrtime() - t0) / 1e6

  t0 = vim.uv.hrtime()
  local commands = capabilities.commands()
  local command_ms = (vim.uv.hrtime() - t0) / 1e6

  local undescribed = 0
  for _, item in ipairs(keymaps) do
    if item.name:match("^no description given") then
      undescribed = undescribed + 1
    end
  end

  say("keymaps_listed", #keymaps)
  say("keymaps_undescribed", undescribed)
  say("keymaps_ms", ("%.1f"):format(keymap_ms))
  say("commands_listed", #commands)
  say("commands_ms", ("%.1f"):format(command_ms))
else
  say("capabilities_error", tostring(capabilities))
end

local ok_search, search = pcall(require, "util.search")
if ok_search then
  local docs, code = 0, 0
  for _, file in ipairs(tracked) do
    local is_docs = false
    for _, glob in ipairs(search.docs_globs()) do
      local pattern = vim.fn.glob2regpat(glob)
      if vim.fn.match(file, pattern) >= 0 then
        is_docs = true
        break
      end
    end
    if is_docs then
      docs = docs + 1
    else
      code = code + 1
    end
  end
  say("docs_files", docs)
  say("code_files", code)
  say("docs_share_pct", #tracked > 0 and ("%.1f"):format(docs / #tracked * 100) or "0")

  local presets = search.presets()
  local names = {}
  for _, preset in ipairs(presets) do
    table.insert(names, preset.name)
  end
  say("search_presets", table.concat(names, ","))
else
  say("search_error", tostring(search))
end

local ok_lsp, lsp = pcall(require, "util.lsp")
if ok_lsp then
  local present = lsp.bin_dirs(assert(vim.uv.cwd()))
  say("project_bin_dirs", #present > 0 and table.concat(present, ",") or "none")
  say("lsp_baseline", table.concat(lsp.baseline or {}, ","))
else
  say("lsp_error", tostring(lsp))
end

local clients = vim.lsp.get_clients({ bufnr = 0 })
local attached = {}
for _, client in ipairs(clients) do
  table.insert(attached, client.name)
end
say("lsp_attached", #attached > 0 and table.concat(attached, ",") or "none")

local messages = vim.split(vim.fn.execute("messages"), "\n", { plain = true })
local errors = {}
for _, line in ipairs(messages) do
  if line:match("[Ee]rror") or line:match("E%d+:") then
    table.insert(errors, vim.trim(line))
  end
end
say("startup_errors", #errors)
for i, err in ipairs(vim.list_slice(errors, 1, 5)) do
  say("error_" .. i, err:sub(1, 160))
end

say("probe_ms", ("%.1f"):format((vim.uv.hrtime() - started) / 1e6))

vim.fn.writefile(out, vim.env.NVIM_STRESS_OUT or "/tmp/nvim-stress.txt")
