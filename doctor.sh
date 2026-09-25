#!/usr/bin/env bash
# Checks a coding-agent cloud environment and prints one PASS/FAIL line per check. Never prints a
# secret value (only whether a variable is set and its length).
#
#   curl -fsSL https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main/doctor.sh | bash
#   curl -fsSL .../doctor.sh | bash -s -- --agents     # also asks each coding agent for a one-word reply
set -u

check_agents=false
[ "${1:-}" = "--agents" ] && check_agents=true
failures=0

report() {
    local status=$1 check=$2 detail=$3
    printf '%-4s  %-34s %s\n' "$status" "$check" "$detail"
    [ "$status" = "FAIL" ] && failures=$((failures + 1))
    return 0
}

tool() {
    local name=$1 version_command=$2 version
    if version=$(eval "$version_command" 2>/dev/null | head -1) && [ -n "$version" ]; then
        report PASS "tool: $name" "$version"
    else
        report FAIL "tool: $name" "not installed (see /var/log/cloud-setup.log)"
    fi
}

variable() {
    local name=$1 required=$2 value
    value=${!name:-}
    if [ -n "$value" ]; then
        report PASS "variable: $name" "set, ${#value} characters"
    elif [ "$required" = required ]; then
        report FAIL "variable: $name" "not set"
    else
        report INFO "variable: $name" "not set (optional)"
    fi
}

# Accept the original Claude-specific key names too (same fallback as session-start.sh).
CLOUD_AWS_ACCESS_KEY_ID=${CLOUD_AWS_ACCESS_KEY_ID:-${CLAUDE_CLOUD_AWS_ACCESS_KEY_ID:-}}
CLOUD_AWS_SECRET_ACCESS_KEY=${CLOUD_AWS_SECRET_ACCESS_KEY:-${CLAUDE_CLOUD_AWS_SECRET_ACCESS_KEY:-}}

echo "== tools"
tool jq 'jq --version'
tool gh 'gh --version'
tool aws 'aws --version'
tool uv 'uv --version'
tool sops 'sops --version'
tool pnpm 'pnpm --version'
tool opencode 'opencode --version'
tool codex 'codex --version'
tool pi 'pi --version'
tool hermes 'hermes --version'

echo "== variables"
variable CLOUD_AWS_ACCESS_KEY_ID required
variable CLOUD_AWS_SECRET_ACCESS_KEY required
variable CLOUD_AWS_PROFILES required
variable CLOUD_AWS_MFA_SERIAL optional
variable CLOUD_AWS_WRITE_TARGETS optional
variable NODE_AUTH_TOKEN required
variable FIREWORKS_API_KEY required
variable CEREBRAS_API_KEY optional

echo "== github"
if login=$(gh api user --jq .login 2>/dev/null) && [ -n "$login" ]; then
    report PASS "github: gh api user" "$login"
else
    report FAIL "github: gh api user" "no response (is the repository attached to the session?)"
fi

echo "== aws profiles"
if [ -z "${CLOUD_AWS_PROFILES:-}" ]; then
    report FAIL "aws: profiles" "CLOUD_AWS_PROFILES is not set"
else
    IFS=',' read -r -a entries <<< "$CLOUD_AWS_PROFILES"
    for entry in "${entries[@]}"; do
        name=${entry%%:*}
        [ -n "$name" ] || continue
        if arn=$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
            aws sts get-caller-identity --profile "$name" --query Arn --output text 2>&1); then
            report PASS "aws: $name" "${arn#arn:aws:sts::}"
        else
            report FAIL "aws: $name" "$(printf '%s' "$arn" | tail -1 | cut -c1-120)"
        fi
    done
fi

if $check_agents; then
    echo "== agents (one-word prompt each)"
    ask() {
        local name=$1 answer
        shift
        if answer=$(cd /tmp && "$@" 2>/dev/null | tr -d '[:space:]' | tail -c 40) && printf '%s' "$answer" | grep -qi 'ok'; then
            report PASS "agent: $name" "answered"
        else
            report FAIL "agent: $name" "no answer (${answer:-empty})"
        fi
    }
    ask opencode opencode run 'Reply with the single word ok'
    ask pi pi -p 'Reply with the single word ok'
    ask hermes hermes -z 'Reply with the single word ok'
    if codex login status 2>&1 | grep -qi 'logged in' && ! codex login status 2>&1 | grep -qi 'not logged'; then
        report PASS "agent: codex" "logged in"
    else
        report INFO "agent: codex" "not logged in; run: codex login --device-auth"
    fi
fi

echo
if [ "$failures" -eq 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; fi
exit 0
