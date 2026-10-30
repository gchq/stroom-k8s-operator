#!/bin/bash
# Renews the proxy's Stroom API key (design 8.1), from a CronJob. The current key's expiry is the date its value was
# written to Secrets Manager (the AWSCURRENT version's CreatedDate; the key is created just before) plus its lifetime.
# Within RENEW_BEFORE_DAYS of that, creates a new key with Stroom's CLI and writes it as the secret's new value. The old
# key stays valid in Stroom until it expires, so the proxy keeps working until it restarts with the new one.
#
# Environment: PROXY_API_KEY_SECRET_ARN, KEY_LIFETIME_DAYS, RENEW_BEFORE_DAYS, AWS_REGION, the settings Stroom's CLI
# needs (as for bootstrap.sh) and EKS Pod Identity's.
set -euo pipefail

WORK=/tmp/renew-proxy-key
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
trap 'rm -rf "$WORK"' EXIT

jq -nc --arg id "$PROXY_API_KEY_SECRET_ARN" '{SecretId: $id}' > "$WORK/list-versions.json"
written=$(secrets_manager ListSecretVersionIds "$WORK/list-versions.json" |
  jq -r '[.Versions[]? | select(.VersionStages | index("AWSCURRENT")) | .CreatedDate][0] // empty | floor')
if [ -z "$written" ]; then
  log "The proxy's API key hasn't been written yet: the bootstrap Job creates it"
  exit 0
fi

# A date from seconds since the epoch (jq: the image's date may not parse @<seconds>)
day() { jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%d")'; }

now=$(date -u +%s)
expires=$((written + KEY_LIFETIME_DAYS * 86400))
renew_from=$((expires - RENEW_BEFORE_DAYS * 86400))
if [ "$now" -lt "$renew_from" ]; then
  log "The proxy's API key expires $(day "$expires"); renewing from $(day "$renew_from")"
  exit 0
fi

log "The proxy's API key expires $(day "$expires"): creating a new one"
create_proxy_key "$WORK/proxy-key"
put_proxy_key "$WORK/proxy-key"
log "Wrote the new key to Secrets Manager; it expires $(day $((now + KEY_LIFETIME_DAYS * 86400))). The proxy uses it once External Secrets has refreshed its Secret and the proxy has restarted; the old key works until it expires."
