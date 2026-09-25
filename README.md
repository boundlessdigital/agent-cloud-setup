# agent-cloud-setup

Sets up a coding-agent cloud environment (Claude Code on the web, and other Ubuntu-based cloud agents) for Boundless work: the tools, the coding agents, and AWS access with no browser login. It is public on purpose. There are no credentials in it. Each person supplies their own through their cloud environment's variables.

## What it installs

| Tool | Notes |
|---|---|
| jq, GitHub CLI | Normally already in the image; installed if missing |
| uv 0.11.19 + Python 3.10.20, graphify | Versions pinned by bng-platform's MCP servers |
| AWS CLI v2, sops 3.13.3, pnpm 10.34.2 | |
| OpenCode, Codex, Pi, Hermes Agent | OpenCode, Pi and Hermes default to DeepSeek V4.1 Flash on Fireworks |

## Set it up (about 5 minutes, once)

**1. In your cloud environment's setup script, put this one line:**

```bash
curl -fsSL https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main/setup.sh | bash
```

On Claude Code on the web: claude.ai/code → the environment's gear icon → **Setup script**. The result is cached for about a week. To pick up a newer version sooner, edit the setup script (adding a comment is enough).

**2. In the environment's variables, add your own values:**

| Variable | Required | What it is |
|---|---|---|
| `CLOUD_AWS_ACCESS_KEY_ID`, `CLOUD_AWS_SECRET_ACCESS_KEY` | For AWS | Your cloud IAM user's access key. Not the standard `AWS_*` names on purpose. |
| `CLOUD_AWS_PROFILES` | For AWS | Your profiles, comma-separated `name:account_id:role:region` |
| `AWS_PROFILE`, `AWS_REGION` | For AWS | The profile and region commands use by default |
| `CLOUD_AWS_MFA_SERIAL`, `CLOUD_AWS_WRITE_TARGETS` | For production write | Your MFA device ARN, and comma-separated `target:account_id:profile:region` |
| `NODE_AUTH_TOKEN` | Yes | GitHub token with `read:packages` (and `write:packages` to publish) |
| `FIREWORKS_API_KEY` | Yes | Model key for OpenCode, Pi and Hermes |
| `CEREBRAS_API_KEY` | No | Optional second model provider |

Ask Sidney for your IAM user, profile list and MFA setup.

**3. Load your AWS profiles at the start of each session.** Cloud machines start fresh, and a setup script can't see your variables, so this runs per session:

```bash
curl -fsSL https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main/session-start.sh | bash
```

In a Claude Code repository you can make this automatic with a `SessionStart` hook in `.claude/settings.json`. bng-platform already has its own. Otherwise, ask the agent to run it first.

**4. Check everything:**

```bash
curl -fsSL https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main/doctor.sh | bash -s -- --agents
```

## Day to day

| Task | How |
|---|---|
| Open production write for one hour | `curl -fsSL …/production-write.sh \| bash -s -- <6-digit code> [target]` |
| Log Codex in | `codex login --device-auth`, then approve on your phone. Needed per session. |
| Use it without a default environment | Run the setup and session-start lines above inside any cloud session |

## Security notes

- The scripts never print a secret. `session-start.sh` removes the key and every profile it wrote if the key variables disappear.
- Environment variables are readable by anything running in the session. Keep the environment personal, and use the narrowest tokens you can.
- The long-lived AWS key can only assume roles. Production write additionally needs an MFA code at most five minutes old, and lasts one hour.
