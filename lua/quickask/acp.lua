-- Minimal ACP (Agent Client Protocol) client over stdio.
-- Speaks newline-delimited JSON-RPC 2.0 with an ACP agent such as
-- @zed-industries/claude-code-acp, which reuses the Claude Code login.
--
-- The agent PROCESS is long-lived (spawning it is slow); SESSIONS on it are
-- cheap, so each new question gets a fresh session while follow-ups reuse it.

local M = {}

local state = {
  config = nil,
  job = nil,
  partial = "",
  next_id = 0,
  pending = {}, -- request id -> callback(result, err)
  proc_ready = false, -- spawned + initialized
  starting = false,
  waiters = {}, -- callbacks queued while the process is starting
  auth_hint = nil, -- agent-advertised login method, for error messages
  session_id = nil,
  session_used = false, -- a prompt was sent in the current session
  preamble_sent = false, -- preamble goes on the first prompt of each session
  handler = nil, -- active prompt: { on_chunk, on_done, on_error }
  stderr_tail = {},
}

function M.setup(config)
  state.config = config
end

local function send_raw(obj)
  if state.job then
    vim.fn.chansend(state.job, vim.json.encode(obj) .. "\n")
  end
end

local function request(method, params, cb)
  state.next_id = state.next_id + 1
  state.pending[state.next_id] = cb
  send_raw({ jsonrpc = "2.0", id = state.next_id, method = method, params = params })
end

local function notify(method, params)
  send_raw({ jsonrpc = "2.0", method = method, params = params })
end

local function respond(id, result, err)
  local msg = { jsonrpc = "2.0", id = id }
  if err then
    msg.error = err
  else
    msg.result = result
  end
  send_raw(msg)
end

-- Agent -> client requests. We expose no filesystem and reject tool
-- permission asks: quick Q&A should be answered from the model directly.
local function handle_agent_request(msg)
  if msg.method == "session/request_permission" then
    local options = (msg.params and msg.params.options) or {}
    local reject
    for _, opt in ipairs(options) do
      if opt.kind == "reject_once" or opt.kind == "reject_always" then
        reject = opt.optionId
        break
      end
    end
    if reject then
      respond(msg.id, { outcome = { outcome = "selected", optionId = reject } })
    else
      respond(msg.id, { outcome = { outcome = "cancelled" } })
    end
  else
    respond(msg.id, nil, { code = -32601, message = "method not supported by quickask" })
  end
end

local function handle_notification(msg)
  if msg.method ~= "session/update" or not state.handler then
    return
  end
  local update = msg.params and msg.params.update
  if update and update.sessionUpdate == "agent_message_chunk" then
    local content = update.content
    if content and content.type == "text" and content.text then
      state.handler.on_chunk(content.text)
    end
  end
end

local function handle_message(msg)
  if msg.id and msg.method then
    handle_agent_request(msg)
  elseif msg.method then
    handle_notification(msg)
  elseif msg.id then
    local cb = state.pending[msg.id]
    state.pending[msg.id] = nil
    if cb then
      cb(msg.result, msg.error)
    end
  end
end

local function on_stdout(_, data)
  data[1] = state.partial .. data[1]
  state.partial = data[#data]
  for i = 1, #data - 1 do
    local line = data[i]
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(msg) == "table" then
        handle_message(msg)
      end
    end
  end
end

local function fail_everything(reason)
  local pending = state.pending
  local handler = state.handler
  state.pending = {}
  state.handler = nil
  state.job = nil
  state.proc_ready = false
  state.starting = false
  state.session_id = nil
  state.session_used = false
  state.preamble_sent = false
  state.partial = ""
  for _, cb in pairs(pending) do
    cb(nil, { message = reason })
  end
  if handler then
    handler.on_error(reason)
  end
  local waiters = state.waiters
  state.waiters = {}
  for _, cb in ipairs(waiters) do
    cb(reason)
  end
end

local function on_exit(_, code)
  local tail = table.concat(state.stderr_tail, " ")
  local reason = ("ACP agent exited (code %d)"):format(code)
  if tail ~= "" then
    reason = reason .. ": " .. tail
  end
  fail_everything(reason)
end

local function on_stderr(_, data)
  for _, line in ipairs(data) do
    if line ~= "" then
      table.insert(state.stderr_tail, line)
      if #state.stderr_tail > 5 then
        table.remove(state.stderr_tail, 1)
      end
    end
  end
end

local function flush_waiters(err)
  local waiters = state.waiters
  state.waiters = {}
  state.starting = false
  for _, cb in ipairs(waiters) do
    cb(err)
  end
end

-- Spawn the agent process and run the ACP initialize handshake.
local function ensure_proc(cb)
  if state.proc_ready then
    cb(nil)
    return
  end
  table.insert(state.waiters, cb)
  if state.starting then
    return
  end
  state.starting = true

  state.stderr_tail = {}
  state.partial = ""
  local job = vim.fn.jobstart(state.config.cmd, {
    env = state.config.env,
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
  })
  if job <= 0 then
    flush_waiters("could not start ACP agent: " .. table.concat(state.config.cmd, " "))
    return
  end
  state.job = job

  request("initialize", {
    protocolVersion = 1,
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false } },
  }, function(init_res, err)
    if err then
      flush_waiters("ACP initialize failed: " .. (err.message or vim.inspect(err)))
      return
    end
    local auth = init_res and init_res.authMethods and init_res.authMethods[1]
    state.auth_hint = auth and (auth.description or auth.name)
    state.proc_ready = true
    flush_waiters(nil)
  end)
end

local function new_session(cb)
  request("session/new", { cwd = vim.uv.cwd(), mcpServers = {} }, function(res, serr)
    if serr or not res or not res.sessionId then
      local detail = serr and (serr.message or vim.inspect(serr)) or "no sessionId returned"
      if state.auth_hint then
        detail = detail .. " (agent may need auth: " .. state.auth_hint .. ")"
      end
      cb("ACP session/new failed: " .. detail)
      return
    end
    state.session_id = res.sessionId
    state.session_used = false
    state.preamble_sent = false
    cb(nil)
  end)
end

-- Process running + some session available (used by preload and follow-ups).
function M.ensure(cb)
  ensure_proc(function(err)
    if err then
      cb(err)
      return
    end
    if state.session_id then
      cb(nil)
      return
    end
    new_session(cb)
  end)
end

-- Process running + a session with no history. Reuses the current session if
-- it's untouched (e.g. the preloaded one); otherwise starts a new one.
function M.fresh(cb)
  ensure_proc(function(err)
    if err then
      cb(err)
      return
    end
    if state.session_id and not state.session_used then
      cb(nil)
      return
    end
    new_session(cb)
  end)
end

function M.busy()
  return state.handler ~= nil
end

-- Send a question. Streams text via on_chunk; calls on_done(stop_reason)
-- or on_error(msg) exactly once.
function M.ask(text, on_chunk, on_done, on_error)
  if state.handler then
    on_error("a question is already in flight")
    return
  end
  M.ensure(function(err)
    if err then
      on_error(err)
      return
    end
    if not state.preamble_sent and state.config.preamble and state.config.preamble ~= "" then
      text = state.config.preamble .. "\n\n" .. text
    end
    state.preamble_sent = true
    state.session_used = true
    state.handler = { on_chunk = on_chunk, on_done = on_done, on_error = on_error }
    request("session/prompt", {
      sessionId = state.session_id,
      prompt = { { type = "text", text = text } },
    }, function(res, perr)
      local handler = state.handler
      state.handler = nil
      if not handler then
        return
      end
      if perr then
        handler.on_error(perr.message or vim.inspect(perr))
      else
        handler.on_done(res and res.stopReason or "end_turn")
      end
    end)
  end)
end

function M.cancel()
  if state.session_id and state.handler then
    notify("session/cancel", { sessionId = state.session_id })
  end
end

-- Kill the agent process entirely; the next ask starts from scratch.
function M.reset()
  if state.job then
    vim.fn.jobstop(state.job)
  end
end

return M
