local M = {}

M.config = {
  keymaps = {
    ask = "<leader>aa", -- normal: ask; visual: ask about selection; window open: follow-up
    ask_cursor = "<leader>ak", -- ask about the word under the cursor, zero typing
    actions = "<leader>aA", -- canned-question menu over selection / current line
  },
  prompt = "Ask: ",
  selection_prompt = "Ask about selection (empty = explain): ",
  followup_prompt = "Follow-up: ",
  -- Extra context sent along with the question (never shown to the model
  -- as coming from you — appended under a "Context" divider).
  context = {
    file = true, -- current file path + filetype
    selection = true, -- visually selected text (enables the visual-mode keymaps)
  },
  -- Canned questions for the actions menu. Each runs against the visual
  -- selection, or the current line in normal mode.
  actions = {
    { name = "Explain", prompt = "Explain this in plain language." },
    { name = "Walk through", prompt = "Walk through what this does, step by step, briefly." },
    { name = "Simplify", prompt = "Show a simpler or more idiomatic way to write this, if one exists." },
    { name = "Spot problems", prompt = "Point out bugs, edge cases, or gotchas in this. Be brief." },
  },
  -- Any ACP agent works here. The plugin is model/vendor agnostic — model
  -- choice, auth, etc. are the agent's concern, configured via cmd/env.
  agent = {
    -- Command that starts the ACP agent. Default: claude-code-acp if
    -- installed, else via npx (slower on the very first run).
    cmd = nil,
    -- Environment for the agent process, e.g. { ANTHROPIC_MODEL = "haiku" }
    -- for claude-code-acp.
    env = {},
  },
  -- Start the agent in the background right after setup so the first
  -- question doesn't pay the process-spawn cost.
  preload = true,
  -- Prepended to the first question of a session.
  preamble = table.concat({
    "You are a quick-reference assistant inside Neovim. The user asks short questions about commands, tools, and programming concepts, and reads your answer in a small popup window.",
    "",
    "Your job is to make the concept land on one read:",
    "- Open with a one-sentence plain-English answer to exactly what was asked.",
    "- If it helps, follow with a short example or a breakdown of the parts (e.g. what each flag does).",
    "- Use everyday words. If a technical term is unavoidable, gloss it in a few words right where it appears.",
    "- Keep the whole answer under roughly 8 lines. Inline code and short fenced blocks are fine.",
    "",
    "Some questions carry a 'Context' section below a divider — the file being edited and/or selected text. Treat it as reference, not as part of the question: when text is selected, answer about that specific text.",
    "",
    "No preamble, no closing questions, no caveats unless they change how the user would act. Do not use tools; answer from knowledge.",
  }, "\n"),
  window = {
    width = 0.62,
    height = 0.5,
    border = "rounded",
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  -- Lists replace, they don't merge: a user-supplied actions list wins whole.
  if opts and opts.actions then
    M.config.actions = opts.actions
  end

  local cmd = M.config.agent.cmd
  if not cmd then
    if vim.fn.executable("claude-code-acp") == 1 then
      cmd = { "claude-code-acp" }
    else
      cmd = { "npx", "--yes", "@zed-industries/claude-code-acp" }
    end
  end

  -- claude-code-acp only: Claude Code refuses to launch nested inside
  -- another Claude Code session (e.g. nvim opened from a Claude Code
  -- terminal). Strip the marker so the agent can start.
  if vim.env.CLAUDECODE and table.concat(cmd, " "):find("claude%-code%-acp") and vim.fn.executable("env") == 1 then
    cmd = vim.list_extend({ "env", "-u", "CLAUDECODE" }, cmd)
  end
  M.config.agent.cmd = cmd

  local acp = require("quickask.acp")
  acp.setup({
    cmd = cmd,
    env = M.config.agent.env,
    preamble = M.config.preamble,
  })

  local maps = M.config.keymaps or {}
  if maps.ask then
    vim.keymap.set("n", maps.ask, function()
      require("quickask.ui").ask()
    end, { desc = "Quick ask (ACP agent)" })

    if M.config.context.selection then
      vim.keymap.set("x", maps.ask, function()
        -- Capture the selection while still in visual mode, then leave it
        -- so vim.ui.input behaves normally.
        local selection = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        vim.schedule(function()
          require("quickask.ui").ask(selection)
        end)
      end, { desc = "Quick ask about selection (ACP agent)" })
    end
  end

  if maps.ask_cursor then
    vim.keymap.set("n", maps.ask_cursor, function()
      require("quickask.ui").ask_cursor()
    end, { desc = "Quick ask: word under cursor" })
  end

  if maps.actions then
    vim.keymap.set("n", maps.actions, function()
      require("quickask.ui").actions()
    end, { desc = "Quick ask: actions menu (current line)" })

    if M.config.context.selection then
      vim.keymap.set("x", maps.actions, function()
        local selection = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        vim.schedule(function()
          require("quickask.ui").actions(selection)
        end)
      end, { desc = "Quick ask: actions menu (selection)" })
    end
  end

  vim.api.nvim_create_user_command("QuickAsk", function(cmd_args)
    local ui = require("quickask.ui")
    if cmd_args.args ~= "" then
      ui.ask_text(cmd_args.args, ui.build_context(), not ui.continuing())
    else
      ui.ask()
    end
  end, { nargs = "?", desc = "Ask the ACP agent a quick question" })

  vim.api.nvim_create_user_command("QuickAskReset", function()
    require("quickask.acp").reset()
  end, { desc = "Restart the quickask agent (fresh conversation)" })

  if M.config.preload then
    vim.defer_fn(function()
      acp.ensure(function(err)
        if err then
          vim.notify("quickask preload: " .. err, vim.log.levels.WARN)
        end
      end)
    end, 300)
  end
end

return M
