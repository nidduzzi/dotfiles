-- Run a language's debugger to a breakpoint without a terminal in the way.
--
-- check-debuggers.sh drives the editor a person drives: tmux, keys, a picker,
-- a frame to read. That is the check worth having, and it does not run on
-- Windows, where there is no tmux. This asks nvim-dap the same question
-- directly -- start this configuration, stop here, what are the arguments --
-- so the adapters can be checked on every platform the configuration claims.
--
-- Usage:
--   nvim --headless --cmd "lua vim.g.debug_headless = { … }" -l debug-headless.lua
--
-- or, as the harness runs it:
--   NVIM_APPNAME=… XDG_CONFIG_HOME=… nvim --headless FIXTURE_FILE \
--     +"luafile debug-headless.lua"
--
-- The case comes from the environment, because a -l script runs before the
-- configuration is loaded and this needs the configuration's adapters.

local case = {
  line = tonumber(vim.env.DEBUG_LINE) or 1,
  choice = tonumber(vim.env.DEBUG_CHOICE) or 1,
  expect = vim.env.DEBUG_EXPECT or "",
  settle = tonumber(vim.env.DEBUG_SETTLE) or 30,
}

vim.o.more = false

local function finish(ok, message)
  -- Flushed, because the quit that follows does not: on a first Windows run
  -- the answer was written and then thrown away with the process.
  io.stdout:write(message .. "\n")
  io.stdout:flush()
  vim.cmd(ok and "qa!" or "cq!")
end

-- Nothing here can answer a question. A project nobody has vouched for asks
-- one the moment a file is opened -- which is the configuration working as
-- intended, and, with no one at the keyboard, a wait with no end to it.
pcall(function()
  require("util.trust").allow(vim.fn.getcwd())
  require("util.trust_menu").forget()
end)

-- Nor can it outlast the job that started it. A session that never answers
-- would otherwise hold a headless editor open until CI gave up on the whole
-- run rather than on this one case.
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

  local configuration = configurations[case.choice]
  if not configuration then
    return finish(false, ("no configuration %d for %s, only %d"):format(case.choice, filetype, #configurations))
  end

  vim.api.nvim_win_set_cursor(0, { case.line, 0 })
  dap.toggle_breakpoint()
  dap.run(configuration)

  -- Polled rather than waited on an event: a session that dies before it
  -- speaks fires nothing, and "nothing happened" is the answer that needs
  -- reporting rather than hanging on.
  local stopped = vim.wait(case.settle * 1000, function()
    local session = dap.session()
    return session ~= nil and session.current_frame ~= nil and session.stopped_thread_id ~= nil
  end, 200)

  local session = dap.session()
  if not stopped or not session or not session.current_frame then
    return finish(false, ("never stopped: %s, session %s"):format(configuration.name, session and "open" or "gone"))
  end

  local frame = session.current_frame
  local where = ("%s:%d"):format(vim.fs.basename((frame.source or {}).path or "?"), frame.line or 0)

  -- Where it stopped is the whole assertion here: a frame carrying a source
  -- path and a line can only have come from an adapter that ran the program.
  -- The driven check reads the variables pane on top of this; what this one
  -- adds is the platforms that have no terminal to drive.
  if case.expect ~= "" and where ~= case.expect then
    return finish(false, ("stopped at %s, expected %s"):format(where, case.expect))
  end

  finish(true, ("stopped at %s"):format(where))
end, 8000)
