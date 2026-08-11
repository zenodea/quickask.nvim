# quickask.nvim

A tiny "quick ask" window for Neovim. Press `<leader>aa`, type a question
("what is grep -rn"), get a streamed answer in a floating markdown window.

- **Agent-agnostic.** Speaks [ACP](https://agentclientprotocol.com) (Agent
  Client Protocol) over stdio — any ACP agent works. The default is
  `claude-code-acp`, which reuses your Claude Code login: no API key.
  Model choice is the agent's concern, not the plugin's.
- **Fast.** The agent process is preloaded in the background at startup and
  kept warm, so asking only pays model latency.
- **The window is the conversation.** While it's open, every ask —
  `<leader>aa`, `<CR>` in the window, a new selection from your code —
  continues the same chat. Close it (`q`/`<Esc>`) and the next ask starts
  fresh: new agent session, cleared window, no stale context.

## Requirements

- Neovim ≥ 0.10
- An ACP agent. For the default:
  - Node.js and [Claude Code](https://claude.com/claude-code) installed and
    logged in (`claude` → `/login`)
  - Recommended: `npm install -g @zed-industries/claude-code-acp`
    (otherwise the plugin falls back to `npx`, which is slow on first run)

## Install (lazy.nvim)

```lua
{
  dir = "~/assistant/quickask.nvim",
  opts = {},
}
```

## Usage

| Mapping / command       | Action                                           |
| ----------------------- | ------------------------------------------------ |
| `<leader>aa` (normal)   | Ask — fresh chat, or follow-up if the window is open |
| `<leader>aa` (visual)   | Ask about the selected text (empty question = "explain this") |
| `<leader>ak`            | "What is `<word under cursor>` here?" — zero typing |
| `<leader>aA` (n/visual) | Canned-question menu (explain / walk through / simplify / spot problems) over the selection or current line |
| `:QuickAsk [question]`  | Same as `<leader>aa`, optionally with the question inline |
| `:QuickAskReset`        | Kill the agent → next ask starts a fresh session |
| `:checkhealth quickask` | Verify Node, the adapter, and do a live agent handshake |
| `q` / `<Esc>` (window)  | Close the conversation (cancels an in-flight answer) |
| `<CR>` (window)         | Ask a follow-up                                  |
| `i` (window)            | Insert the answer's code block at the spot you asked from |
| `y` (window)            | Yank the whole conversation to `+` and `"`       |

Questions automatically carry lightweight context: the file you're editing
(path + filetype), and in visual mode the selected text (shown in the window
under your question, and fenced with the buffer's filetype for the model).
Asking from inside the window attaches no file context.

## Configuration (defaults)

```lua
require("quickask").setup({
  keymaps = {
    ask = "<leader>aa",
    ask_cursor = "<leader>ak",
    actions = "<leader>aA",   -- set any of these to false to disable
  },
  prompt = "Ask: ",
  selection_prompt = "Ask about selection (empty = explain): ",
  followup_prompt = "Follow-up: ",
  context = {
    file = true,            -- mention current file path + filetype
    selection = true,       -- visual-mode keymaps + selected text as context
  },
  actions = {               -- the <leader>aA menu; replace wholesale to customize
    { name = "Explain", prompt = "Explain this in plain language." },
    { name = "Walk through", prompt = "Walk through what this does, step by step, briefly." },
    { name = "Simplify", prompt = "Show a simpler or more idiomatic way to write this, if one exists." },
    { name = "Spot problems", prompt = "Point out bugs, edge cases, or gotchas in this. Be brief." },
  },
  agent = {
    cmd = nil,              -- auto: claude-code-acp, else npx @zed-industries/claude-code-acp
    env = {},               -- environment for the agent process
  },
  preload = true,           -- warm the agent at startup
  preamble = "...",         -- terse-answer instruction prepended to the first question
  window = { width = 0.62, height = 0.5, border = "rounded" },
})
```

### Picking a model / a different agent

The plugin never touches model selection — configure it on the agent:

```lua
-- Claude Code agent, pinned to Haiku for speed:
agent = { env = { ANTHROPIC_MODEL = "haiku" } }

-- A different ACP agent entirely, e.g. Gemini CLI:
agent = { cmd = { "gemini", "--experimental-acp" } }
```

## Notes

- Tool/permission requests from the agent are auto-rejected — this is a
  knowledge lookup window, not a coding agent. The preamble also tells the
  model not to reach for tools.
- Each new ask gets a fresh session on the warm agent process (cheap — no
  respawn). Only `<CR>` follow-ups share history. `:QuickAskReset` kills the
  whole process if the agent ever wedges.
