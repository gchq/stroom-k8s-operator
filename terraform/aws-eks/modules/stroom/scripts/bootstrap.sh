#!/bin/bash
# Sets up a new Stroom cluster (design 5.4). Every step is idempotent, so the Job can run again whenever its inputs
# change. Runs in the Stroom image, as the stroom user, against the cluster's database (CLI) and its API.
#
# Environment:
#   ADMIN_SUBJECT, ADMIN_DISPLAY_NAME   the first administrator's IdP identity (uniqueIdentityClaim) and name
#   API_BASE                            the Frontend Service's API, e.g. https://stroom-dev-ui-http.stroom.svc:8443/api
#   CA_FILE                             the in-cluster CA certificate, which signs the nodes' certificates
#   PROCESSING_NODES                    space-separated names of the nodes that run the S3 event poll
#   DATA_BUCKET, AWS_REGION             the data bucket the S3 read-only volume reads
#   PROXY_API_KEY_SECRET_ARN            Secrets Manager secret for the proxy's API key; empty for no proxy
#   KEY_LIFETIME_DAYS                   lifetime of the proxy's API key (renew-proxy-key.sh renews it)
#   AWS_CONTAINER_CREDENTIALS_FULL_URI, AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE   EKS Pod Identity
set -euo pipefail

WORK=/tmp/bootstrap
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
trap 'rm -rf "$WORK"' EXIT

S3_JOB="S3 Event Notifications Poll"
S3_VOLUME_GROUP="S3 data bucket"
cd /stroom

# --- 1. Users and keys, with the CLI (on the database) ---------------------------------------------------------------

users=(--createUser "$ADMIN_SUBJECT,$ADMIN_DISPLAY_NAME" --grantPermission "$ADMIN_SUBJECT" "Administrator"
       --createUser "stroom-bootstrap" --grantPermission "stroom-bootstrap" "Administrator")
if [ -n "${PROXY_API_KEY_SECRET_ARN:-}" ]; then
  users+=(--createUser "stroom-proxy" --grantPermission "stroom-proxy" "Stroom Proxy")
fi
log "Creating users"
./start.sh manage_users "${users[@]}"

# A short-lived key for this run's API calls. Key names are unique per user, so each run gets its own.
log "Creating the bootstrap API key"
./start.sh create_api_key -u stroom-bootstrap -n "bootstrap-$(date -u +%Y%m%d%H%M%S)" -e 1 -o "$WORK/bootstrap-key"
api_key=$(< "$WORK/bootstrap-key")

# The proxy's key, once: the renewal CronJob replaces it before it expires
if [ -n "${PROXY_API_KEY_SECRET_ARN:-}" ]; then
  jq -nc --arg id "$PROXY_API_KEY_SECRET_ARN" '{SecretId: $id}' > "$WORK/describe-secret.json"
  versions=$(secrets_manager DescribeSecret "$WORK/describe-secret.json" | jq '.VersionIdsToStages // {} | length')
  if [ "$versions" -gt 0 ]; then
    log "The proxy's API key already exists"
  else
    log "Creating the proxy's API key"
    create_proxy_key "$WORK/proxy-key"
    put_proxy_key "$WORK/proxy-key"
    rm -f "$WORK/proxy-key"
    log "Wrote the proxy's API key to Secrets Manager"
  fi
fi

# --- 2. The API, once the nodes are up ---------------------------------------------------------------------------------

# api_call <curl options array name> <method> <path> [JSON body]: Stroom's API with the bootstrap key
api_call() {
  local -n opts=$1
  local method=$2 path=$3 data=()
  if [ -n "${4:-}" ]; then
    printf '%s' "$4" > "$WORK/api-body.json"
    data=(--data-binary "@$WORK/api-body.json")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$api_key" |
    curl "${opts[@]}" --config - --cacert "$CA_FILE" -X "$method" -H 'Content-Type: application/json' \
      "${data[@]}" "$API_BASE$path"
}
# Retries transient failures; fails the script if they persist
api() { api_call CURL_RETRY "$@"; }
# One attempt, for the loops that wait for the nodes: the caller checks the result
api_try() { api_call CURL_ONCE "$@"; }

log "Waiting for the Stroom API"
for _ in $(seq 1 360); do
  api_try GET /job/v1 > /dev/null 2>&1 && break
  sleep 10
done
api GET /job/v1 > /dev/null

# The S3 read-only volume, in a group of its own: write-volume selection doesn't skip read-only volumes
s3_config=$(jq -nc --arg region "$AWS_REGION" --arg bucket "$DATA_BUCKET" '{region: $region, bucketName: $bucket}')
existing=$(api POST /fsVolume/v1/find '{"selection":{"matchAll":true}}' |
  jq --arg c "$s3_config" '[.values[] | select(.volumeType == "S3_V1_READ_ONLY" and (.s3ClientConfigData | fromjson) == ($c | fromjson))] | length')
if [ "$existing" -gt 0 ]; then
  log "The S3 volume for $DATA_BUCKET already exists"
else
  group_id=$(api GET "/fsVolume/volumeGroup/v2/fetchByName/$(jq -rn --arg n "$S3_VOLUME_GROUP" '$n | @uri')" | jq -r '.id // empty')
  if [ -z "$group_id" ]; then
    group_id=$(api POST /fsVolume/volumeGroup/v2 "$(jq -nc --arg n "$S3_VOLUME_GROUP" '$n')" | jq -r .id)
  fi
  api POST /fsVolume/v1 "$(jq -nc --argjson g "$group_id" --arg c "$s3_config" \
    '{volumeType: "S3_V1_READ_ONLY", volumeGroup: {id: $g}, s3ClientConfigData: $c}')" > /dev/null
  log "Created the S3 volume for $DATA_BUCKET"
fi

# The S3 event poll: enabled globally, and on each processing node once that node has started (its job rows exist).
# A failed attempt (the node not up yet, a transient error) is tried again.
job_id=$(api GET /job/v1 | jq -r --arg n "$S3_JOB" '.values[] | select(.name == $n) | .id')
api PUT "/job/v1/$job_id/enabled" 'true' > /dev/null
enable_body=$(jq -nc --arg j "$S3_JOB" '{enabled: true, includeJobs: [$j]}')
for node in $PROCESSING_NODES; do
  modified=0
  for _ in $(seq 1 180); do
    if result=$(api_try PUT "/job/v1/setJobsEnabled/$node" "$enable_body" 2> /dev/null); then
      modified=$(jq -r '.modifiedCount // 0' <<<"$result")
      [ "$modified" -gt 0 ] && break
    fi
    sleep 10
  done
  [ "$modified" -gt 0 ] || { log "Node $node has no '$S3_JOB' job yet: has it started?"; exit 1; }
  log "Enabled '$S3_JOB' on $node"
done

log "Bootstrap complete"
