-- Run a language's debugger to a breakpoint without a terminal in the way,
-- so it can be checked on platforms with no tmux (Windows).
--
-- Usage, as the harness runs it:
--   NVIM_APPNAME=… XDG_CONFIG_HOME=… nvim --headless FIXTURE_FILE \
--     +"luafile debug-headless.lua"
--
-- The case comes from the environment: a -l script runs before the
-- configuration loads, and this needs its adapters.

local case = {
  line = tonumber(vim.env.DEBUG_LINE) or 1,
  choice = tonumber(vim.env.DEBUG_CHOICE) or 1,
  expect = vim.env.DEBUG_EXPECT or "",
  settle = tonumber(vim.env.DEBUG_SETTLE) or 30,
}

vim.o.more = false

-- A notification goes nowhere in a headless editor, so capture it here.
local notices = {}
local notify = vim.notify
vim.notify = function(message, level, opts)
  notices[#notices + 1] = tostring(message):gsub("%s+", " ")
  return notify(message, level, opts)
end

local function finish(ok, message)
  io.stdout:write(message .. "\n")
  io.stdout:flush()
  vim.cmd(ok and "qa!" or "cq!")
end

-- An untrusted project asks a question with no one at the keyboard to answer.
pcall(function()
  require("util.trust").allow(vim.fn.getcwd())
  require("util.trust_menu").forget()
end)

-- A session that never answers would otherwise hold this open until CI
-- gives up on the whole run rather than on this one case.
vim.defer_fn(function()
  io.stdout:write("never stopped: gave up waiting\n")
  vim.cmd("cq!")
end, (case.settle + 40) * 1000)

vim.defer_fn(function()
  local started, dap = pcall(require, "dap")
  if not started then
    return finish(false, "no nvim-dap: " .. tostring(dap))
  end

  local filetype = vim.bo.filetype
  local configurations = dap.configurations[filetype] or {}
  if #configurations == 0 then
    return finish(false, ("no configurations for %s"):format(filetype))
  end

  -- Headless: no screen to draw on, pinned to the fixture's own server, own
  -- profile -- none of which belongs in the real configuration.
  if vim.env.DEBUG_BROWSER_HEADLESS == "1" then
    for _, offered in ipairs(configurations) do
      if offered.type == "pwa-chrome" then
        offered.runtimeArgs = { "--headless=new", "--no-sandbox", "--disable-gpu" }
        offered.userDataDir = true
        if offered.url then
          offered.url = offered.url:gsub("localhost", "127.0.0.1")
        end
      end
    end
  end

  local configuration = configurations[case.choice]
  if not configuration then
    return finish(false, ("no configuration %d for %s, only %d"):format(case.choice, filetype, #configurations))
  end

  pcall(dap.set_log_level, "TRACE")

  vim.api.nvim_win_set_cursor(0, { case.line, 0 })
  dap.toggle_breakpoint()
  dap.run(configuration)

  -- Polled, not waited on an event: a session that dies before it speaks
  -- fires nothing.
  local stopped = vim.wait(case.settle * 1000, function()
    local session = dap.session()
    return session ~= nil and session.current_frame ~= nil and session.stopped_thread_id ~= nil
  end, 200)

  local session = dap.session()
  if not stopped or not session or not session.current_frame then
    -- nvim-dap's own log is at stdpath("log") -- an alias for stdpath("state"),
    -- not stdpath("cache").
    local said = {}
    local log = vim.fn.stdpath("log") .. "/dap.log"
    if vim.uv.fs_stat(log) then
      local lines = vim.fn.readfile(log)
      for index = math.max(1, #lines - 30), #lines do
        said[#said + 1] = (lines[index] or ""):gsub("%s+", " ")
      end
    end
    return finish(
      false,
      ("never stopped: %s, session %s -- %s -- said: %s -- adapter: %s"):format(
        configuration.name,
        session and "open" or "gone",
        #said > 0 and table.concat(said, " | ") or "the adapter logged nothing",
        #notices > 0 and table.concat(notices, " / ") or "nothing",
        (vim.inspect(dap.adapters[configuration.type] or "no adapter"):gsub("%s+", " "))
      )
    )
  end

  local frame = session.current_frame
  local where = ("%s:%d"):format(vim.fs.basename((frame.source or {}).path or "?"), frame.line or 0)

  if case.expect ~= "" and where ~= case.expect then
    return finish(false, ("stopped at %s, expected %s"):format(where, case.expect))
  end

  finish(true, ("stopped at %s"):format(where))
end, 8000)
