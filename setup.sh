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

# The cloud image sets UV_NATIVE_TLS, which uv 0.11 deprecated in favor of UV_SYSTEM_CERTS (same
# meaning: use the machine's certificate store) and warns about on every run. Carry the value over
# to the new name, here for this script's own uv calls and in every shell start-up below.
UV_TLS_MIGRATION='if [ -n "${UV_NATIVE_TLS:-}" ]; then export UV_SYSTEM_CERTS="${UV_SYSTEM_CERTS:-$UV_NATIVE_TLS}"; unset UV_NATIVE_TLS; fi'
eval "$UV_TLS_MIGRATION"
for rc in /etc/bash.bashrc "$HOME/.bashrc" "$HOME/.profile"; do
  grep -q 'UV_SYSTEM_CERTS' "$rc" 2>/dev/null || printf '\n# agent-cloud-setup: uv deprecated UV_NATIVE_TLS; use UV_SYSTEM_CERTS\n%s\n' "$UV_TLS_MIGRATION" >> "$rc"
done

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

# sops: the release's prebuilt binary, checked against its published SHA-256. (Compiling it with
# `go install` took minutes and was the slowest step of the whole setup.)
(
  case "$(uname -m)" in aarch64|arm64) sops_arch=arm64 ;; *) sops_arch=amd64 ;; esac
  sops_file="sops-v3.13.3.linux.$sops_arch"
  cd /tmp && curl -fsSL "https://github.com/getsops/sops/releases/download/v3.13.3/$sops_file" -o "$sops_file" \
    && curl -fsSL https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.checksums.txt \
      | grep " $sops_file\$" | sha256sum -c - >/dev/null \
    && install -m 755 "$sops_file" /usr/local/bin/sops
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

# Hermes Agent (Nous Research), official installer. --skip-setup skips its interactive wizard;
# --skip-browser skips its Chromium download, the other slow step. Add it back in a session with
# `hermes pm install agent-browser` if you need Hermes to drive a browser.
(
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --skip-browser >/tmp/hermes-install.log 2>&1 \
    && ln -sf "$HOME/.local/bin/hermes" /usr/local/bin/hermes
) || log "WARN: hermes install failed (see /tmp/hermes-install.log)" &

wait
log "tools installed: jq $(jq --version 2>/dev/null), gh $(gh --version 2>/dev/null | head -1 | cut -d' ' -f3), uv $(uv --version 2>/dev/null | cut -d' ' -f2), aws $(aws --version 2>/dev/null | cut -d' ' -f1), sops $(sops --version 2>/dev/null | head -1 | cut -d' ' -f2), pnpm $(pnpm --version 2>/dev/null), opencode $(opencode --version 2>/dev/null), codex $(codex --version 2>/dev/null | cut -d' ' -f2), pi $(pi --version 2>/dev/null), hermes $(hermes --version 2>/dev/null | head -1)"

# 2. AWS credentials. A setup script does not see the environment's variables, so the credentials
#    are written at run time instead, automatically, whatever the repository or agent:
#    - cloud-session-start runs session-start.sh once per machine start-up (a boot-id marker makes
#      repeat calls free);
#    - every shell start-up calls it (/etc/bash.bashrc, ~/.bashrc, ~/.profile), which covers the
#      shells coding agents open to run commands;
#    - aws and sops get wrappers in /usr/local/sbin (ahead of /usr/local/bin on PATH) that call it
#      before running the real program, for commands started without a shell start-up.
REPO_RAW=${AGENT_CLOUD_SETUP_RAW:-https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main}
mkdir -p /usr/local/lib/agent-cloud-setup
if curl -fsSL "$REPO_RAW/session-start.sh" -o /usr/local/lib/agent-cloud-setup/session-start.sh \
  && curl -fsSL "$REPO_RAW/production-write.sh" -o /usr/local/lib/agent-cloud-setup/production-write.sh \
  && curl -fsSL "$REPO_RAW/doctor.sh" -o /usr/local/lib/agent-cloud-setup/doctor.sh; then
  chmod 755 /usr/local/lib/agent-cloud-setup/*.sh
  ln -sf /usr/local/lib/agent-cloud-setup/production-write.sh /usr/local/bin/cloud-production-write
  ln -sf /usr/local/lib/agent-cloud-setup/doctor.sh /usr/local/bin/cloud-doctor
  cat > /usr/local/bin/cloud-session-start <<'EOF7'
#!/bin/bash
# Runs agent-cloud-setup's session-start.sh once per machine start-up. Always exits 0.
marker=/tmp/.cloud-session-start.$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo boot)
[ -e "$marker" ] && exit 0
CLOUD_AGENT=1 bash /usr/local/lib/agent-cloud-setup/session-start.sh >/dev/null 2>&1
touch "$marker" 2>/dev/null
exit 0
EOF7
  chmod 755 /usr/local/bin/cloud-session-start
  for rc in /etc/bash.bashrc "$HOME/.bashrc" "$HOME/.profile"; do
    grep -q 'cloud-session-start' "$rc" 2>/dev/null || printf '\n# agent-cloud-setup: load AWS profiles once per machine start-up\n[ -x /usr/local/bin/cloud-session-start ] && /usr/local/bin/cloud-session-start\n' >> "$rc"
  done
  mkdir -p /usr/local/sbin
  for tool in aws sops; do
    printf '#!/bin/bash\n/usr/local/bin/cloud-session-start\nexec /usr/local/bin/%s "$@"\n' "$tool" > "/usr/local/sbin/$tool"
    chmod 755 "/usr/local/sbin/$tool"
  done
else
  log "WARN: could not download session-start.sh; AWS profiles will need a manual run"
fi

# cloud-update: re-runs the latest setup.sh inside the current session (new tools, versions and
# config), then reloads the AWS profiles so a changed session-start.sh takes effect too. New
# sessions keep using the cached build until the environment's setup script is edited.
cat > /usr/local/bin/cloud-update <<EOF8
#!/bin/bash
set -o pipefail
curl -fsSL "$REPO_RAW/setup.sh" | bash || { echo "cloud-update: setup failed (see /var/log/cloud-setup.log)" >&2; exit 1; }
rm -f /tmp/.cloud-session-start.*
/usr/local/bin/cloud-session-start
echo "cloud-update: done. Run cloud-doctor to check."
EOF8
chmod 755 /usr/local/bin/cloud-update

# A note every coding agent reads at start-up, so "update yourself" or "check the environment"
# works in any repository. Written between markers, so it is replaced on each run and anything
# else in these files is kept. (Claude Code: ~/.claude/CLAUDE.md; Codex: ~/.codex/AGENTS.md;
# OpenCode: ~/.config/opencode/AGENTS.md.)
agent_note='<!-- agent-cloud-setup:start -->
## Cloud environment (agent-cloud-setup)

This machine was set up by https://github.com/boundlessdigital/agent-cloud-setup (public, no secrets).

| Task | Command |
|---|---|
| Update this session to the latest setup (tools, agents, config) | `cloud-update` |
| Check tools, variables, GitHub and every AWS profile | `cloud-doctor` (add `--agents` to test the coding agents) |
| Reload AWS profiles by hand (normally automatic) | `cloud-session-start` |
| Open one hour of production write access | `cloud-production-write <6-digit MFA code> [target]` |
| See what the setup script did and how long it took | `/var/log/cloud-setup.log` (the setup script itself is in the environment'"'"'s settings, not in the repository) |

These are the environment owner'"'"'s own tools: when asked to update, check or repair the environment, run them. They never print secrets. `cloud-update` changes only this session; new sessions use the cached build until the environment'"'"'s setup script is edited.
<!-- agent-cloud-setup:end -->'
for note_file in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"; do
  mkdir -p "$(dirname "$note_file")"
  kept=$(awk '/<!-- agent-cloud-setup:start -->/{skip=1} !skip{print} /<!-- agent-cloud-setup:end -->/{skip=0}' "$note_file" 2>/dev/null)
  { [ -n "$kept" ] && printf '%s\n\n' "$kept"; printf '%s\n' "$agent_note"; } > "$note_file"
done

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
