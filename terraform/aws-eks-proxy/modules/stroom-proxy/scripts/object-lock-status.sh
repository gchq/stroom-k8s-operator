#!/usr/bin/env bash
#
# Terraform "external" data source: reports an existing bucket's versioning
# and Object Lock settings, which the AWS provider can't read.
#
# Input (stdin, JSON):  {"bucket": "...", "region": "..."}
# Output (stdout, JSON): {"versioning": "...", "object_lock": "...", "mode": "...", "retention": "..."}
#
# Needs the AWS CLI and python3, with credentials that can read the bucket's
# configuration.

set -euo pipefail

input="$(cat)"
bucket="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["bucket"])' "${input}")"
region="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["region"])' "${input}")"

versioning="$(aws s3api get-bucket-versioning --region "${region}" --bucket "${bucket}" \
  --query 'Status' --output text 2>/dev/null || echo "")"

# Fails if the bucket has no Object Lock configuration at all.
lock="$(aws s3api get-object-lock-configuration --region "${region}" --bucket "${bucket}" \
  --output json 2>/dev/null || echo '{}')"

python3 -c '
import json, sys
versioning, lock = sys.argv[1], json.loads(sys.argv[2] or "{}")
conf = lock.get("ObjectLockConfiguration", {})
retention = conf.get("Rule", {}).get("DefaultRetention", {})
days = retention.get("Days") or (retention.get("Years") and retention["Years"] * 365) or ""
print(json.dumps({
    "versioning": "" if versioning == "None" else versioning,
    "object_lock": conf.get("ObjectLockEnabled", ""),
    "mode": retention.get("Mode", ""),
    "retention": str(days),
}))
' "${versioning}" "${lock}"
