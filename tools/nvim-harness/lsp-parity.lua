--- Exercise every capability a language server advertises, and report what answered.
---
--- A server saying it supports a request is not the same as the editor being
--- able to make it: the capability may be advertised, unbound, and therefore
--- untested. This sends each request the attached servers claim to support and
--- records what came back, so "we have parity with the VS Code extension" is a
--- measurement rather than a belief.
---
--- Set NVIM_LSP_PARITY to a path for the report, and NVIM_LSP_PARITY_CLIENT to
--- one server's name to ask only that one.

local report = {}
local wanted = vim.env.NVIM_LSP_PARITY_CLIENT

local function line(text)
  table.insert(report, text or "")
end

-- Driven with no file open, this asked the dashboard buffer what servers had
-- attached to it, which is never any of them: the loop over clients ran zero
-- times and the report was one line, "cursor: ...", with nothing about a
-- language server at all -- true of every run so far, reported as if the
-- probe had checked something.
local target = vim.env.NVIM_LSP_PARITY_FILE
if target and target ~= "" then
  vim.cmd.edit(target)
  vim.wait(15000, function()
    return #vim.lsp.get_clients({ bufnr = 0 }) > 0
  end, 100)
end

local bufnr = vim.api.nvim_get_current_buf()
local clients = vim.lsp.get_clients({ bufnr = bufnr })

if target and target ~= "" and #clients == 0 then
  line(("no language server attached to %s after 15s"):format(target))
end

--- Put the cursor on something worth asking about. A keyword or a comment
--- answers "nothing here" for every request, which looks like a server that
--- does not work rather than a cursor in the wrong place, so NVIM_LSP_PARITY_SYMBOL
--- names an identifier to sit on.
local symbol = vim.env.NVIM_LSP_PARITY_SYMBOL
local placed = false

if symbol and symbol ~= "" then
  for row = 1, vim.api.nvim_buf_line_count(bufnr) do
    local text = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local column = text:find(symbol, 1, true)
    if column then
      vim.api.nvim_win_set_cursor(0, { row, column - 1 })
      placed = true
      break
    end
  end
end

if not placed then
  for row = 1, vim.api.nvim_buf_line_count(bufnr) do
    local text = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local column = text:find("%a%w%w")
    if column and not text:match("^%s*#") then
      vim.api.nvim_win_set_cursor(0, { row, column - 1 })
      break
    end
  end
end

line(("cursor: %s"):format(vim.inspect(vim.api.nvim_win_get_cursor(0))))

local position = vim.lsp.util.make_position_params(0, "utf-16")
local range = vim.lsp.util.make_range_params(0, "utf-16")
local document = { textDocument = position.textDocument }

--- Every request worth asking, with the capability that advertises it.
---@type { method: string, capability: string, params: table|fun():table }[]
local checks = {
  { method = "textDocument/hover", capability = "hoverProvider", params = position },
  { method = "textDocument/definition", capability = "definitionProvider", params = position },
  { method = "textDocument/declaration", capability = "declarationProvider", params = position },
  { method = "textDocument/typeDefinition", capability = "typeDefinitionProvider", params = position },
  { method = "textDocument/implementation", capability = "implementationProvider", params = position },
  {
    method = "textDocument/references",
    capability = "referencesProvider",
    params = vim.tbl_extend("force", position, { context = { includeDeclaration = true } }),
  },
  { method = "textDocument/documentSymbol", capability = "documentSymbolProvider", params = document },
  {
    method = "workspace/symbol",
    capability = "workspaceSymbolProvider",
    params = { query = "a" },
  },
  { method = "textDocument/documentHighlight", capability = "documentHighlightProvider", params = position },
  { method = "textDocument/signatureHelp", capability = "signatureHelpProvider", params = position },
  {
    method = "textDocument/completion",
    capability = "completionProvider",
    params = vim.tbl_extend("force", position, { context = { triggerKind = 1 } }),
  },
  { method = "textDocument/prepareRename", capability = "renameProvider", params = position },
  { method = "textDocument/prepareCallHierarchy", capability = "callHierarchyProvider", params = position },
  { method = "textDocument/prepareTypeHierarchy", capability = "typeHierarchyProvider", params = position },
  {
    method = "textDocument/inlayHint",
    capability = "inlayHintProvider",
    params = vim.tbl_extend("force", document, {
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1), character = 0 },
      },
    }),
  },
  { method = "textDocument/foldingRange", capability = "foldingRangeProvider", params = document },
  {
    method = "textDocument/selectionRange",
    capability = "selectionRangeProvider",
    params = vim.tbl_extend("force", document, { positions = { position.position } }),
  },
  { method = "textDocument/semanticTokens/full", capability = "semanticTokensProvider", params = document },
  { method = "textDocument/codeLens", capability = "codeLensProvider", params = document },
  {
    method = "textDocument/formatting",
    capability = "documentFormattingProvider",
    params = vim.tbl_extend("force", document, { options = { tabSize = 4, insertSpaces = true } }),
  },
}

--- Code action kinds are asked for separately: a server advertises which it
--- answers, and a refactor menu that offers nothing is the thing being checked.
local function action_kinds(client)
  local provider = (client.server_capabilities or {}).codeActionProvider
  if type(provider) == "table" and provider.codeActionKinds then
    return provider.codeActionKinds
  end
  return {}
end

local pending = 0
local done = false

local function finish()
  local out = vim.env.NVIM_LSP_PARITY
  if out and out ~= "" then
    vim.fn.writefile(report, out)
  else
    print(table.concat(report, "\n"))
  end
  done = true
end

for _, client in ipairs(clients) do
  if not wanted or client.name == wanted then
    line(("== %s =="):format(client.name))

    for _, check in ipairs(checks) do
      local supported = (client.server_capabilities or {})[check.capability]

      if not supported then
        line(("  %-42s not advertised"):format(check.method))
      else
        pending = pending + 1
        local params = type(check.params) == "function" and check.params() or check.params

        client:request(check.method, params, function(err, result)
          local outcome
          if err then
            outcome = "ERROR " .. (err.message or vim.inspect(err))
          elseif result == nil then
            outcome = "answered, nothing here"
          elseif type(result) == "table" and vim.islist(result) then
            outcome = ("answered, %d item(s)"):format(#result)
          else
            outcome = "answered"
          end

          line(("  %-42s %s"):format(check.method, outcome))
          pending = pending - 1
        end, bufnr)
      end
    end

    -- Code actions, one request per kind the server claims. A refactor kind
    -- wants a selection to work on, not an empty range under the cursor, so
    -- the request covers the block the cursor sits in.
    for _, kind in ipairs(action_kinds(client)) do
      pending = pending + 1
      local params = vim.deepcopy(range)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      params.range = {
        start = { line = row - 1, character = 0 },
        ["end"] = { line = math.min(row + 3, vim.api.nvim_buf_line_count(bufnr)) - 1, character = 0 },
      }
      params.context = { diagnostics = {}, only = { kind } }

      client:request("textDocument/codeAction", params, function(err, result)
        local outcome
        if err then
          outcome = "ERROR " .. (err.message or "")
        else
          outcome = ("%d action(s)"):format(result and #result or 0)
        end
        line(("  codeAction %-34s %s"):format(kind, outcome))
        pending = pending - 1
      end, bufnr)
    end
  end
end

-- Requests answer on their own schedule; wait for them rather than reporting
-- an empty result and calling it parity.
vim.defer_fn(function()
  local waited = 0
  local function check_again()
    if pending <= 0 or waited > 8000 then
      finish()
      return
    end
    waited = waited + 250
    vim.defer_fn(check_again, 250)
  end
  check_again()
end, 500)

vim.wait(12000, function()
  return done
end, 100)
