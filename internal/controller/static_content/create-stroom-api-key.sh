#!/bin/bash 
# Expects the following env vars to be set:
# POD_NAMESPACE
# STROOM_API_KEY_SECRET_NAME
# STROOM_API_KEY_EXPIRY_DAYS (Optional)
# JAVA_OPTS
#

set -euo pipefail

: "${POD_NAMESPACE:?must be set.}"
: "${STROOM_API_KEY_SECRET_NAME:?must be set to the name of the Secret to write the key to}"

# Optional: defaults to Stroom's maximum key lifetime
expiry_days="${STROOM_API_KEY_EXPIRY_DAYS:-365}"
if ! [[ "$expiry_days" =~ ^[1-9][0-9]*$ ]]; then
  echo "STROOM_API_KEY_EXPIRY_DAYS must be a positive whole number, got '${expiry_days}'" >&2
  exit 1
fi

user=stroom-k8s-operator
keyfile=/tmp/api-key/key
keyname=k8s-operator-$(date +%s)

cd /stroom

# Create stroom-k8s-user if it doesn't already exist 
./start.sh manage_users \
  --createUser stroom-k8s-operator \
  --grantPermission stroom-k8s-operator "Manage Nodes" \
  --grantPermission stroom-k8s-operator "Manage Jobs" \
  --grantPermission stroom-k8s-operator "Manage Tasks"

# Create api key for the stroom cluster to use
./start.sh create_api_key -u stroom-operator -n "$key_name" -e "$expiry_days" -o /tmp/api-key/key

sa_dir=/var/run/secrets/kubernetes.io/serviceaccount
secret_url="https://kubernetes.default.svc/api/v1/namespaces/${POD_NAMESPACE}/secrets/${STROOM_API_KEY_SECRET_NAME}"
expires_epoch=$(( $(date +%s) + expiry_days * 86400 ))

# Build the JSON body with jq so quoting is always correct
patch_body=$(jq -n \
  --rawfile key "$keyfile" \
  --arg name "$keyname" \
  --arg expires "$expires_epoch" \
  '{
     metadata: {
       annotations: {
         "stroom.gchq.github.io/api-key-expires": $expires,
         "stroom.gchq.github.io/api-key-name": $name
       }
     },
     stringData: { apiKey: $key }
   }')

echo "Writing API key '${keyname}' to Secret ${POD_NAMESPACE}/${STROOM_API_KEY_SECRET_NAME}"
if ! response=$(curl --silent --show-error --fail-with-body \
      --request PATCH \
      --cacert "${sa_dir}/ca.crt" \
      --header "Authorization: Bearer $(cat "${sa_dir}/token")" \
      --header 'Content-Type: application/merge-patch+json' \
      --data "$patch_body" \
      "$secret_url"); then
  echo "Failed to write API key to Secret: ${response}" >&2
  exit 1
fi

rm -f "$keyfile"
echo "API key written to Secret"
