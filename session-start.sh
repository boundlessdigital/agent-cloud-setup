#!/usr/bin/env bash
# Writes AWS CLI profiles for a coding-agent cloud session from the person's own environment
# variables, so every AWS command works without a browser login. Run it at the start of each
# session (a cloud VM starts fresh):
#
#   curl -fsSL https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main/session-start.sh | bash
#
# It needs, in the cloud environment's variables (see README.md):
#   CLOUD_AWS_ACCESS_KEY_ID, CLOUD_AWS_SECRET_ACCESS_KEY
#       One long-lived key for a user whose only power is assuming roles. Deliberately NOT the
#       standard AWS_ACCESS_KEY_ID names: the AWS CLI and SDKs prefer those over AWS_PROFILE, so
#       every command would run as the bare user.
#   CLOUD_AWS_PROFILES
#       The profiles to create, comma-separated, each  name:account_id:role_name:region
#       e.g.  dev:111111111111:ClaudeCloudAdmin:us-east-1,prod-readonly:222222222222:ClaudeCloudReadOnly:us-east-2
#
# It writes the key to ~/.aws/credentials as the profile cloud-base and one role profile per entry
# to ~/.aws/config, replacing only the sections it owns (anything else in both files is kept). If
# the key variables are missing it removes what it wrote before, so a stale key never lingers.
# It never prints a secret and always exits 0, so it can never block a session.
#
# Outside a cloud session it does nothing unless CLOUD_AGENT=1 is set. Claude Code cloud sessions
# are detected by CLAUDE_CODE_REMOTE=true.
set -u

LOG_FILE=${CLOUD_SESSION_LOG:-/tmp/cloud-session-start.log}
BASE_PROFILE=${CLOUD_AWS_BASE_PROFILE:-cloud-base}
BASE_REGION=${CLOUD_AWS_BASE_REGION:-us-east-1}
# Targets production-write.sh can open (target:account_id:profile_name:region, comma-separated).
# Their profiles are removed together with everything else if the key goes away.
WRITE_TARGETS=${CLOUD_AWS_WRITE_TARGETS:-}

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Print FILE without the INI sections whose header name is in the "|"-separated list NAMES.
without_sections() {
    local file=$1 names=$2
    [ -f "$file" ] || return 0
    awk -v names="$names" '
        BEGIN { count = split(names, list, "|"); for (i = 1; i <= count; i++) drop[list[i]] = 1 }
        /^[[:space:]]*\[/ {
            header = $0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", header)
            sub(/[[:space:]]*\][[:space:]]*$/, "", header)
            skipping = (header in drop)
        }
        !skipping { print }
    ' "$file"
}

# Rewrite FILE without NAMES and with the text read from stdin appended; atomic, mode 600.
replace_sections() {
    local file=$1 names=$2 new_text kept temp
    new_text=$(cat)
    kept=$(without_sections "$file" "$names" | awk 'NF { for (; b > 0; b--) print ""; print; next } { b++ }')
    temp=$(mktemp "$file.XXXXXX")
    chmod 600 "$temp"
    {
        [ -n "$kept" ] && printf '%s\n\n' "$kept"
        [ -n "$new_text" ] && printf '%s\n' "$new_text"
    } > "$temp"
    mv "$temp" "$file"
    chmod 600 "$file"
}

main() {
    if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ] && [ "${CLOUD_AGENT:-}" != "1" ]; then
        return 0
    fi

    # Accept the original Claude-specific names too, so existing environments keep working.
    local key_id=${CLOUD_AWS_ACCESS_KEY_ID:-${CLAUDE_CLOUD_AWS_ACCESS_KEY_ID:-}}
    local secret=${CLOUD_AWS_SECRET_ACCESS_KEY:-${CLAUDE_CLOUD_AWS_SECRET_ACCESS_KEY:-}}
    local profiles=${CLOUD_AWS_PROFILES:-}

    umask 077
    mkdir -p "$HOME/.aws" && chmod 700 "$HOME/.aws"

    # Every section this script (or production-write.sh) may have written on an earlier start.
    local owned_credentials="$BASE_PROFILE" owned_config="profile $BASE_PROFILE" entry name rest
    local IFS_SAVED=$IFS
    IFS=','
    for entry in $profiles; do
        name=${entry%%:*}
        [ -n "$name" ] || continue
        owned_config="$owned_config|profile $name"
    done
    local account
    for entry in $WRITE_TARGETS; do
        IFS=":" read -r _ account name rest <<< "$entry"
        [ -n "$name" ] || continue
        owned_config="$owned_config|profile $name"
        owned_credentials="$owned_credentials|$name"
    done
    IFS=$IFS_SAVED

    if [ -z "$key_id" ] || [ -z "$secret" ]; then
        # Fail closed: drop the key and every profile built on it.
        replace_sections "$HOME/.aws/credentials" "$owned_credentials" < /dev/null
        replace_sections "$HOME/.aws/config" "$owned_config" < /dev/null
        log "cleared: CLOUD_AWS_ACCESS_KEY_ID or CLOUD_AWS_SECRET_ACCESS_KEY is not set"
        return 0
    fi

    printf '[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$BASE_PROFILE" "$key_id" "$secret" |
        replace_sections "$HOME/.aws/credentials" "$BASE_PROFILE"

    local block count=0 role region
    block=$(printf '[profile %s]\nregion = %s\n' "$BASE_PROFILE" "$BASE_REGION")
    IFS=','
    for entry in $profiles; do
        IFS=':' read -r name account role region rest <<< "$entry"
        if [ -z "$name" ] || [ -z "$account" ] || [ -z "$role" ]; then
            log "skipped malformed CLOUD_AWS_PROFILES entry (need name:account_id:role_name:region)"
            continue
        fi
        block=$(printf '%s\n\n[profile %s]\nrole_arn = arn:aws:iam::%s:role/%s\nsource_profile = %s\nregion = %s\n' \
            "$block" "$name" "$account" "$role" "$BASE_PROFILE" "${region:-$BASE_REGION}")
        count=$((count + 1))
    done
    IFS=$IFS_SAVED

    # Replace the base profile and every currently listed profile; other sections are kept.
    printf '%s\n' "$block" | replace_sections "$HOME/.aws/config" "$owned_config"
    log "configured: profile $BASE_PROFILE and $count role profiles"
}

main "$@" || log "failed: unexpected error (exit $?)"
exit 0
