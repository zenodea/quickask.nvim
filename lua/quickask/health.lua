local M = {}

function M.check()
  local health = vim.health
  health.start("quickask")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim 0.10+ required (uses vim.fn.getregion, vim.uv)")
  end

  local ok, qa = pcall(require, "quickask")
  if not ok or not qa.config.agent.cmd then
    health.error("quickask.setup() has not run — is the plugin configured?")
    return
  end

  local cmd = qa.config.agent.cmd
  health.info("agent command: " .. table.concat(cmd, " "))
  local bin = cmd[1] == "env" and cmd[4] or cmd[1]
  if vim.fn.executable(bin) == 1 then
    health.ok(("`%s` is executable"):format(bin))
  else
    health.error(("`%s` not found on PATH"):format(bin))
    return
  end
  if bin == "npx" then
    health.warn("using the npx fallback — `npm install -g @zed-industries/claude-code-acp` makes agent startup faster")
  end
  if vim.env.CLAUDECODE then
    health.info("running inside a Claude Code session — CLAUDECODE is stripped from the agent env (nested-launch guard)")
  end

  health.info("running a live ACP handshake (spawn + initialize + session, up to 30s)...")
  local acp = require("quickask.acp")
  local done, err_msg = false, nil
  acp.ensure(function(err)
    done, err_msg = true, err
  end)
  vim.wait(30000, function()
    return done
  end, 200)

  if not done then
    health.error("agent did not respond within 30s (first npx run can be slow — try again)")
  elseif err_msg then
    health.error("handshake failed: " .. err_msg)
  else
    health.ok("agent initialized and session created (left warm for your first ask)")
  end
end

return M
