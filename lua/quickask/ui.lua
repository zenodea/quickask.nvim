-- Floating window UI: prompt via vim.ui.input, streamed markdown response.

local acp = require("quickask.acp")

local M = {}

local ui = {
  buf = nil,
  win = nil,
  streaming = false,
  -- Buffer/row the user asked from, so answers can be inserted back.
  origin = nil,
}

local function win_valid()
  return ui.win and vim.api.nvim_win_is_valid(ui.win)
end

local function buf_valid()
  return ui.buf and vim.api.nvim_buf_is_valid(ui.buf)
end

local function config()
  return require("quickask").config
end

local function close()
  if ui.streaming then
    acp.cancel()
    ui.streaming = false
  end
  if win_valid() then
    vim.api.nvim_win_close(ui.win, true)
  end
  ui.win = nil
end

-- Fenced code blocks of the last answer (i.e. after the last "**Q:**" line),
-- skipping the echoed-selection block that directly follows the Q header.
function M._extract_code_block()
  if not buf_valid() then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
  local q_idx = 0
  for i, line in ipairs(lines) do
    if line:match("^%*%*Q:%*%*") then
      q_idx = i
    end
  end
  local block, in_block, block_start
  for i = q_idx + 1, #lines do
    if lines[i]:match("^```") then
      if not in_block then
        in_block, block_start, block = true, i, {}
      else
        in_block = false
        if block_start ~= q_idx + 1 and #block > 0 then
          return block -- first real block of the answer
        end
        block = nil
      end
    elseif in_block then
      table.insert(block, lines[i])
    end
  end
  return nil
end

local function insert_code_block()
  local block = M._extract_code_block()
  if not block then
    vim.notify("quickask: no code block in the answer", vim.log.levels.WARN)
    return
  end
  local o = ui.origin
  if o and vim.api.nvim_buf_is_valid(o.buf) and not vim.bo[o.buf].readonly then
    vim.api.nvim_buf_set_lines(o.buf, o.row, o.row, false, block)
    close()
    local win = vim.fn.bufwinid(o.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { o.row + 1, 0 })
    end
    vim.notify(("quickask: inserted %d line(s)"):format(#block), vim.log.levels.INFO)
  else
    vim.fn.setreg('"', table.concat(block, "\n") .. "\n")
    vim.notify("quickask: origin gone — code block yanked to \" instead", vim.log.levels.WARN)
  end
end

local function open_window(title)
  local w = config().window
  local width = math.floor(vim.o.columns * w.width)
  local height = math.floor(vim.o.lines * w.height)

  if not buf_valid() then
    ui.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[ui.buf].buftype = "nofile"
    vim.bo[ui.buf].bufhidden = "hide"
    vim.bo[ui.buf].swapfile = false
    vim.bo[ui.buf].filetype = "markdown"
    vim.bo[ui.buf].modifiable = false

    local opts = { buffer = ui.buf, nowait = true, silent = true }
    vim.keymap.set("n", "q", close, opts)
    vim.keymap.set("n", "<Esc>", close, opts)
    vim.keymap.set("n", "<CR>", function()
      M.ask() -- window is open, so this continues the conversation
    end, opts)
    vim.keymap.set("n", "i", insert_code_block, opts)
    vim.keymap.set("n", "y", function()
      local text = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
      vim.fn.setreg("+", text)
      vim.fn.setreg('"', text)
      vim.notify("quickask: conversation yanked", vim.log.levels.INFO)
    end, opts)
  end

  if title and #title > width - 6 then
    title = title:sub(1, width - 9) .. "..."
  end

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = w.border,
    title = title and (" " .. title .. " ") or " quickask ",
    title_pos = "center",
  }
  if win_valid() then
    vim.api.nvim_win_set_config(ui.win, win_opts)
  else
    ui.win = vim.api.nvim_open_win(ui.buf, true, win_opts)
    vim.wo[ui.win].wrap = true
    vim.wo[ui.win].linebreak = true
    vim.wo[ui.win].conceallevel = 2
  end
end

local function write(fn)
  if not buf_valid() then
    return
  end
  vim.bo[ui.buf].modifiable = true
  fn(ui.buf)
  vim.bo[ui.buf].modifiable = false
  if win_valid() then
    local last = vim.api.nvim_buf_line_count(ui.buf)
    vim.api.nvim_win_set_cursor(ui.win, { last, 0 })
  end
end

local function append(text)
  write(function(buf)
    local chunks = vim.split(text, "\n", { plain = true })
    local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
    chunks[1] = last .. chunks[1]
    vim.api.nvim_buf_set_lines(buf, -2, -1, false, chunks)
  end)
end

local function append_lines(lines)
  write(function(buf)
    local count = vim.api.nvim_buf_line_count(buf)
    local empty = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    vim.api.nvim_buf_set_lines(buf, empty and 0 or count, -1, false, lines)
  end)
end

-- Capture context from the buffer the user is currently in. Must be called
-- BEFORE any window/prompt is opened. `selection` is an optional list of
-- lines (from visual mode).
function M.build_context(selection)
  local cfg = config().context
  local cur = vim.api.nvim_get_current_buf()
  if cur ~= ui.buf then
    ui.origin = { buf = cur, row = vim.api.nvim_win_get_cursor(0)[1] }
  end

  local name = vim.api.nvim_buf_get_name(cur)
  local ft = vim.bo[cur].filetype
  local ctx = { ft = ft }
  local parts = {}

  if cfg.file and name ~= "" and cur ~= ui.buf then
    local pretty = vim.fn.fnamemodify(name, ":~:.")
    ctx.file = pretty
    table.insert(parts, ("The user is editing `%s`%s."):format(pretty, ft ~= "" and (" (filetype: " .. ft .. ")") or ""))
  end
  if cfg.selection and selection and #selection > 0 then
    ctx.selection = selection
    table.insert(parts, "They have this text selected:\n```" .. ft .. "\n" .. table.concat(selection, "\n") .. "\n```")
  end

  if #parts == 0 then
    return nil
  end
  ctx.suffix = "\n\n---\nContext (for reference; the question is above):\n" .. table.concat(parts, "\n\n")
  return ctx
end

-- Ask a question. `ctx` is a table from build_context(), or nil for none.
-- `fresh` starts a new conversation: clears the window and the agent session.
function M.ask_text(question, ctx, fresh)
  -- ui.streaming covers the agent-startup window where acp.busy() is
  -- still false but an ask is already in flight.
  if ui.streaming or acp.busy() then
    vim.notify("quickask: still answering the previous question", vim.log.levels.WARN)
    return
  end

  if fresh and buf_valid() then
    write(function(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end)
  end

  open_window(question)
  local header = { "**Q:** " .. question }
  if ctx and ctx.selection then
    table.insert(header, "```" .. (ctx.ft or ""))
    vim.list_extend(header, ctx.selection)
    table.insert(header, "```")
  end
  vim.list_extend(header, { "", "" })
  append_lines(header)
  ui.streaming = true

  local function on_error(err)
    ui.streaming = false
    append_lines({ "", "**error:** " .. err, "" })
    vim.notify("quickask: " .. err, vim.log.levels.ERROR)
  end

  local function send()
    local payload = question .. (ctx and ctx.suffix or "")
    local got_chunk = false
    acp.ask(payload, function(chunk)
      got_chunk = true
      append(chunk)
    end, function(stop_reason)
      ui.streaming = false
      if not got_chunk then
        append("*(no response — stop reason: " .. stop_reason .. ")*")
      end
      append_lines({ "", "---", "" })
    end, on_error)
  end

  if fresh then
    acp.fresh(function(err)
      if err then
        on_error(err)
      else
        send()
      end
    end)
  else
    send()
  end
end

-- True while the window is open with an ongoing conversation in it.
function M.continuing()
  return win_valid() and buf_valid() and vim.api.nvim_buf_line_count(ui.buf) > 1
end

-- Entry point for the keymaps. While the window is open, asks continue the
-- current conversation; once it's closed, the next ask starts fresh.
-- Context (file/selection) is captured from the buffer you're in — asking
-- from inside the quickask window attaches none (it has no file).
function M.ask(selection)
  local continuing = M.continuing()
  local ctx = M.build_context(selection)

  local prompt = config().prompt
  if selection then
    prompt = config().selection_prompt
  elseif continuing then
    prompt = config().followup_prompt
  end

  vim.ui.input({ prompt = prompt }, function(input)
    if input == nil then
      return -- cancelled
    end
    if not input:match("%S") then
      if selection then
        input = "Explain this." -- selected something, asked nothing: explain it
      else
        return
      end
    end
    M.ask_text(input, ctx, not continuing)
  end)
end

-- Zero-typing ask about the word under the cursor, grounded by the current line.
function M.ask_cursor()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    vim.notify("quickask: no word under cursor", vim.log.levels.WARN)
    return
  end
  local ctx = M.build_context({ vim.api.nvim_get_current_line() })
  M.ask_text(("What is `%s` here?"):format(word), ctx, not M.continuing())
end

-- Pick a canned question from config().actions and run it against the
-- selection (visual mode) or the current line (normal mode).
function M.actions(selection)
  selection = selection or { vim.api.nvim_get_current_line() }
  local ctx = M.build_context(selection) -- capture before the picker opens
  local continuing = M.continuing()
  vim.ui.select(config().actions, {
    prompt = "QuickAsk",
    format_item = function(a)
      return a.name
    end,
  }, function(choice)
    if choice then
      M.ask_text(choice.prompt, ctx, not continuing)
    end
  end)
end

function M.toggle()
  if win_valid() then
    close()
  elseif buf_valid() then
    open_window(nil)
  else
    M.ask()
  end
end

return M
