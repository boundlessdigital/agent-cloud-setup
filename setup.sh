#!/bin/bash
# Installs the tools and coding agents for a Boundless coding-agent cloud environment (Claude Code on
# the web, and other Ubuntu-based cloud agents). Put this one line in the environment's setup script:
#
#   curl -fsSL https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main/setup.sh | bash
#
# Contains NO secrets: every key comes from the environment's variables at run time (see README.md).
# Runs as root, once per cached environment build. Must exit 0 and finish within ~5 minutes.
# Status lines are kept in /var/log/cloud-setup.log.

set -u
# The script's own status lines are also appended to /var/log/cloud-setup.log. (Redirecting the
# whole script through tee kept the output stream open and the setup step never finished.)
log() { echo "[cloud-setup] $(date -u +%H:%M:%S) $*" | tee -a /var/log/cloud-setup.log; }
log "start"

# 1. Tools the repo depends on that the base image lacks or has at the wrong version.
#    uv and Python are pinned by scripts/mcp/run_mcp_package.mjs (REVIEWED_UV_VERSION,
#    REVIEWED_PYTHON_VERSION); the AWS MCP servers refuse to start on other versions.
(
  # The image ships an older uv in /root/.local/bin; replace it there so it wins on PATH.
  curl -LsSf https://astral.sh/uv/0.11.19/install.sh | env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh \
    && ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv && ln -sf "$HOME/.local/bin/uvx" /usr/local/bin/uvx \
    && uv python install 3.10.20 \
    && uv tool install graphifyy==0.9.47 \
    && ln -sf "$HOME/.local/bin/graphify" /usr/local/bin/graphify
) || log "WARN: uv/python/graphify install failed" &

(
  cd /tmp && curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscli.zip \
    && unzip -q -o awscli.zip && ./aws/install --update
) || log "WARN: aws cli install failed" &

(
  GOBIN=/usr/local/bin go install github.com/getsops/sops/v3/cmd/sops@v3.13.3
) || log "WARN: sops install failed" &

(corepack enable && corepack prepare pnpm@10.34.2 --activate) || log "WARN: pnpm 10.34.2 activation failed" &

# jq and the GitHub CLI ship with the base image; install them only if a future image drops them.
# gh needs no login in the cloud: the session's GitHub proxy substitutes your own credentials.
(command -v jq >/dev/null || (apt-get update -qq && apt-get install -y -qq jq)) || log "WARN: jq install failed" &
(command -v gh >/dev/null || (apt-get update -qq && apt-get install -y -qq gh)) || log "WARN: gh install failed" &

# Coding agents, pinned to the versions the team uses. OpenCode, Pi and Hermes read their model
# keys from FIREWORKS_API_KEY / CEREBRAS_API_KEY. Codex signs in per session with
# `codex login --device-auth` (a code approved on your phone), because a copied ChatGPT login
# stops working once it refreshes.
(npm install -g --silent opencode-ai@1.18.31 @openai/codex@0.155.1 @earendil-works/pi-coding-agent@0.83.0) \
  || log "WARN: opencode/codex/pi install failed" &

# Hermes Agent (Nous Research), official installer; --skip-setup skips its interactive wizard.
(
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup >/tmp/hermes-install.log 2>&1 \
    && ln -sf "$HOME/.local/bin/hermes" /usr/local/bin/hermes
) || log "WARN: hermes install failed (see /tmp/hermes-install.log)" &

wait
log "tools installed: jq $(jq --version 2>/dev/null), gh $(gh --version 2>/dev/null | head -1 | cut -d' ' -f3), uv $(uv --version 2>/dev/null | cut -d' ' -f2), aws $(aws --version 2>/dev/null | cut -d' ' -f1), sops $(sops --version 2>/dev/null | head -1 | cut -d' ' -f2), pnpm $(pnpm --version 2>/dev/null), opencode $(opencode --version 2>/dev/null), codex $(codex --version 2>/dev/null | cut -d' ' -f2), pi $(pi --version 2>/dev/null), hermes $(hermes --version 2>/dev/null | head -1)"

# 2. AWS credentials are NOT set up here: a setup script does not see the environment's variables.
#    session-start.sh in this repo writes ~/.aws at the start of every session instead.

# 3. GitHub Packages login for every Boundless repo (app and libraries), same as the Mac.
#    pnpm 10 refuses to expand ${VAR} in a repository .npmrc, so it must be the user-level ~/.npmrc.
#    ~/.npmrc references ${NODE_AUTH_TOKEN}, so no token value is written to disk. The token
#    needs read:packages (pnpm install) and write:packages (npm publish of boundless-ui / meraki-sdk).
cat > "$HOME/.npmrc" <<'EOF2'
@boundlessdigital:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
EOF2

# 4. Agent configuration. No secrets here: every agent reads its keys from the environment.
mkdir -p "$HOME/.config/opencode" "$HOME/.codex"
cat > "$HOME/.config/opencode/opencode.jsonc" <<'EOF3'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "fireworks-ai/accounts/fireworks/models/deepseek-v4p1-flash",
  "provider": {
    "fireworks-ai": { "options": { "apiKey": "{env:FIREWORKS_API_KEY}" } },
    "cerebras": { "options": { "apiKey": "{env:CEREBRAS_API_KEY}" } }
  }
}
EOF3
[ -f "$HOME/.codex/config.toml" ] || printf 'model = "gpt-6-astra"\n' > "$HOME/.codex/config.toml"
mkdir -p "$HOME/.pi/agent"
cat > "$HOME/.pi/agent/settings.json" <<'EOF4'
{ "defaultProvider": "fireworks", "defaultModel": "accounts/fireworks/models/deepseek-v4p1-flash", "quietStartup": true }
EOF4
# Pi's built-in Fireworks catalog has no deepseek-v4p1-flash (it silently fell back to another
# provider), so add it. Limits from Fireworks: 1,048,576-token context, tools and images supported;
# a 393,216-token max_tokens request is accepted. $FIREWORKS_API_KEY is expanded by Pi at run time.
cat > "$HOME/.pi/agent/models.json" <<'EOF6'
{
  "providers": {
    "fireworks": {
      "baseUrl": "https://api.fireworks.ai/inference/v1",
      "api": "openai-completions",
      "apiKey": "$FIREWORKS_API_KEY",
      "models": [
        {
          "id": "accounts/fireworks/models/deepseek-v4p1-flash",
          "name": "DeepSeek V4.1 Flash",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 1048576,
          "maxTokens": 393216
        }
      ]
    }
  }
}
EOF6
# Hermes' installer writes its own config.yaml (default model anthropic/claude-opus-4.6, provider
# auto), so set the two model fields with its own command instead of writing the file.
if command -v hermes >/dev/null; then
  hermes config set model.provider fireworks >/dev/null 2>&1 \
    && hermes config set model.default accounts/fireworks/models/deepseek-v4p1-flash >/dev/null 2>&1 \
    || log "WARN: could not set the hermes model"
fi

log "done"
exit 0
