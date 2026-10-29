#!/bin/bash
#
# Syncs DataFeedIdentities JSON files from S3 into the proxy's data feed
# identities directory.
#
#   s3-sync.sh --once   sync once and exit (init container)
#   s3-sync.sh          sync every DFK_SYNC_INTERVAL seconds (sidecar)
#
# The proxy watches that directory and reloads a file when it is created,
# modified or deleted. So files are never written in place: each is
# downloaded to a staging directory first, then copied to a temporary name
# (not ending .json, so the proxy ignores it) and renamed, which is atomic.
#
# Environment: DFK_BUCKET, DFK_PREFIX, DFK_DIR, DFK_STAGING_DIR,
# DFK_SYNC_INTERVAL. AWS credentials come from EKS Pod Identity.

set -euo pipefail

src="s3://${DFK_BUCKET}/${DFK_PREFIX}"
dest="${DFK_DIR}"
staging="${DFK_STAGING_DIR}"

sync_once() {
  # Only *.json directly under the prefix: the proxy doesn't read
  # subdirectories. --delete removes staged files that have gone from S3.
  # Downloaded files get the object's LastModified time as their mtime.
  # Return before touching the proxy's directory if the download fails
  # (set -e doesn't apply inside a function called from "||").
  if ! aws s3 sync "${src}" "${staging}" \
      --delete --exact-timestamps --only-show-errors \
      --exclude "*" --include "*.json" --exclude "*/*"; then
    return 1
  fi

  local changed=0 removed=0 file name

  for file in "${staging}"/*.json; do
    [ -e "${file}" ] || continue
    name="$(basename "${file}")"
    if [ ! -e "${dest}/${name}" ] || [ "${file}" -nt "${dest}/${name}" ] || [ "${file}" -ot "${dest}/${name}" ]; then
      cp -p "${file}" "${dest}/.${name}.tmp"
      mv -f "${dest}/.${name}.tmp" "${dest}/${name}"
      changed=$((changed + 1))
    fi
  done

  for file in "${dest}"/*.json; do
    [ -e "${file}" ] || continue
    name="$(basename "${file}")"
    if [ ! -e "${staging}/${name}" ]; then
      rm -f "${file}"
      removed=$((removed + 1))
    fi
  done

  if [ "${changed}" -gt 0 ] || [ "${removed}" -gt 0 ]; then
    echo "$(date -u +%FT%TZ) synced ${src}: ${changed} updated, ${removed} removed"
  fi
}

if [ "${1:-}" = "--once" ]; then
  sync_once
  exit 0
fi

while true; do
  sync_once || echo "$(date -u +%FT%TZ) sync from ${src} failed; keeping the current files" >&2
  sleep "${DFK_SYNC_INTERVAL}"
done
