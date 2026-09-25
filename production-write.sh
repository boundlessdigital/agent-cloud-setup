#!/usr/bin/env bash
# Opens one hour of write access to an MFA-protected AWS account from a coding-agent cloud session,
# using a 6-digit code from the person's authenticator app. The AWS CLI would normally prompt for
# the code, which a cloud session cannot answer, so this calls sts:AssumeRole once with the code and
# stores the temporary credentials under the target's profile name.
#
#   curl -fsSL https://raw.githubusercontent.com/boundlessdigital/agent-cloud-setup/main/production-write.sh | bash -s -- 123456 production
#
# It needs, in the cloud environment's variables (see README.md):
#   CLOUD_AWS_MFA_SERIAL      ARN of the MFA device on the cloud IAM user
#   CLOUD_AWS_WRITE_TARGETS   comma-separated  target:account_id:profile_name:region
#                             e.g. production:222222222222:prod:us-east-2
#   CLOUD_AWS_WRITE_ROLE      role to assume in the target account (default ClaudeCloudProductionWrite)
# and the cloud-base profile written by session-start.sh.
#
# Prints only the profile name and the expiry time, never the credentials.
set -euo pipefail

BASE_PROFILE=${CLOUD_AWS_BASE_PROFILE:-cloud-base}
WRITE_ROLE=${CLOUD_AWS_WRITE_ROLE:-ClaudeCloudProductionWrite}
SESSION_SECONDS=3600

usage() {
    echo "usage: production-write.sh <6-digit-code> [target]   (targets: ${CLOUD_AWS_WRITE_TARGETS:-none configured})" >&2
    exit 2
}

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ] && [ "${CLOUD_AGENT:-}" != "1" ]; then
    echo "Refusing to run outside a cloud session (set CLOUD_AGENT=1 if this is one). Locally, use SSO." >&2
    exit 1
fi
[ -n "${CLOUD_AWS_MFA_SERIAL:-}" ] || { echo "CLOUD_AWS_MFA_SERIAL is not set." >&2; exit 1; }
[ -n "${CLOUD_AWS_WRITE_TARGETS:-}" ] || { echo "CLOUD_AWS_WRITE_TARGETS is not set." >&2; exit 1; }

code=${1:-}
[[ "$code" =~ ^[0-9]{6}$ ]] || usage
target=${2:-${CLOUD_AWS_WRITE_TARGETS%%:*}}

account_id='' profile='' region=''
IFS=',' read -r -a entries <<< "$CLOUD_AWS_WRITE_TARGETS"
for entry in "${entries[@]}"; do
    IFS=':' read -r row_target row_account row_profile row_region <<< "$entry"
    if [ "$row_target" = "$target" ]; then
        account_id=$row_account profile=$row_profile region=${row_region:-us-east-1}
    fi
done
[ -n "$account_id" ] && [ -n "$profile" ] || usage

# Clear any credentials in the environment so the call really uses the cloud-base profile.
result=$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE \
    aws sts assume-role \
    --profile "$BASE_PROFILE" \
    --role-arn "arn:aws:iam::$account_id:role/$WRITE_ROLE" \
    --role-session-name "cloud-write-$(date -u +%Y%m%dT%H%M%S)" \
    --serial-number "$CLOUD_AWS_MFA_SERIAL" \
    --token-code "$code" \
    --duration-seconds "$SESSION_SECONDS" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken,Expiration]' \
    --output text)

read -r access_key_id secret_access_key session_token expiration <<< "$result"
[ -n "${expiration:-}" ] || { echo "AWS returned no credentials; nothing was written." >&2; exit 1; }

umask 077
mkdir -p "$HOME/.aws" && chmod 700 "$HOME/.aws"

# Replace only this profile's section in each file, keeping everything else.
write_section() {
    local file=$1 header=$2 body=$3 kept temp
    kept=$(awk -v drop="$header" '
        /^[[:space:]]*\[/ { h = $0; sub(/^[[:space:]]*\[[[:space:]]*/, "", h); sub(/[[:space:]]*\][[:space:]]*$/, "", h); skip = (h == drop) }
        !skip { print }' "$file" 2>/dev/null | awk 'NF { for (; b > 0; b--) print ""; print; next } { b++ }')
    temp=$(mktemp "$file.XXXXXX")
    chmod 600 "$temp"
    { [ -n "$kept" ] && printf '%s\n\n' "$kept"; printf '[%s]\n%s\n' "$header" "$body"; } > "$temp"
    mv "$temp" "$file"
    chmod 600 "$file"
}

write_section "$HOME/.aws/credentials" "$profile" \
    "$(printf 'aws_access_key_id = %s\naws_secret_access_key = %s\naws_session_token = %s' "$access_key_id" "$secret_access_key" "$session_token")"
# A config entry with only the region: no role_arn or mfa_serial, so the CLI never prompts.
write_section "$HOME/.aws/config" "profile $profile" "region = $region"

echo "Profile $profile is ready until $expiration (use --profile $profile or AWS_PROFILE=$profile)."
