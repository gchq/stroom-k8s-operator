#!/bin/bash
# Shared by bootstrap.sh and renew-proxy-key.sh; sourced, with WORK set to a directory of the pod's own (an emptyDir).
#
# Secrets never go in a command's arguments, which any process on the node can read in /proc/<pid>/cmdline: curl reads
# them from a config file on its stdin, written with bash builtins, and request bodies holding them are files in WORK.
#
# Environment: AWS_REGION, and EKS Pod Identity's AWS_CONTAINER_CREDENTIALS_FULL_URI and
# AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE.

: "${WORK:?}"
umask 077
mkdir -p "$WORK"

# Every curl gives up on a dead connection and a hung request. With retries, it tries again after timeouts, refused
# connections and HTTP 408, 429, 500, 502, 503 and 504.
CURL_ONCE=(--silent --show-error --fail --connect-timeout 10 --max-time 120)
CURL_RETRY=("${CURL_ONCE[@]}" --retry 5 --retry-delay 5 --retry-connrefused)

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# The pod's AWS credentials (JSON), from the Pod Identity agent
aws_credentials() {
  printf 'header = "Authorization: %s"\n' "$(< "$AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")" |
    curl "${CURL_RETRY[@]}" --config - "$AWS_CONTAINER_CREDENTIALS_FULL_URI"
}

# secrets_manager <operation> <JSON body file>: calls Secrets Manager, signed by curl with the pod's credentials
secrets_manager() {
  local operation=$1 body_file=$2 creds
  creds=$(aws_credentials)
  printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\n' \
      "$(jq -r .AccessKeyId <<<"$creds")" "$(jq -r .SecretAccessKey <<<"$creds")" "$(jq -r .Token <<<"$creds")" |
    curl "${CURL_RETRY[@]}" --config - --aws-sigv4 "aws:amz:${AWS_REGION}:secretsmanager" \
      -H "X-Amz-Target: secretsmanager.${operation}" -H 'Content-Type: application/x-amz-json-1.1' \
      --data-binary "@$body_file" "https://secretsmanager.${AWS_REGION}.amazonaws.com/"
}

# put_proxy_key <key file>: writes the key in the file as the proxy key secret's new current value
put_proxy_key() {
  jq -nc --arg id "$PROXY_API_KEY_SECRET_ARN" --rawfile key "$1" '{SecretId: $id, SecretString: ($key | rtrimstr("\n"))}' \
    > "$WORK/put-secret.json"
  secrets_manager PutSecretValue "$WORK/put-secret.json" > /dev/null
  rm -f "$WORK/put-secret.json"
}

# create_proxy_key <key file>: creates a key for the stroom-proxy user, lasting KEY_LIFETIME_DAYS, with Stroom's CLI
create_proxy_key() {
  (cd /stroom && ./start.sh create_api_key -u stroom-proxy -n "proxy-$(date -u +%Y%m%d%H%M%S)" \
    -e "$KEY_LIFETIME_DAYS" -o "$1")
}
