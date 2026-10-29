#!/usr/bin/env bash
#
# Renders the stroom-proxy chart with each values file in
# charts/stroom-proxy/ci/ and checks the generated config.yml with the proxy
# image's own config validation (Dropwizard "check" command). The proxy
# rejects unknown keys, so this catches config that would stop it booting,
# e.g. after the proxy image version changes.
#
# Needs helm (or HELM=/path/to/helm), docker, curl and python3.
#
#   hack/validate-stroom-proxy-chart.sh [image]
#
# image defaults to gchq/stroom-proxy:<chart appVersion>.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${repo_root}/charts/stroom-proxy"
app_version="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${chart}/Chart.yaml")"
image="${1:-gchq/stroom-proxy:${app_version}}"
helm="${HELM:-helm}"
# Render for the cluster version actually deployed; older Helm releases
# otherwise assume an old Kubernetes and fail the chart's kubeVersion check.
kube_version="${KUBE_VERSION:-1.37.0}"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

# Pull out data."config.yml" from the rendered ConfigMap (a literal block
# scalar), without needing a YAML library.
extract_config() {
  python3 -c '
import sys
lines = sys.stdin.read().splitlines()
out, inside, indent = [], False, None
for line in lines:
    if not inside:
        if line.strip() == "config.yml: |":
            inside = True
            key_indent = len(line) - len(line.lstrip())
        continue
    if line.strip() and len(line) - len(line.lstrip()) <= key_indent:
        break
    if indent is None and line.strip():
        indent = len(line) - len(line.lstrip())
    out.append(line[indent:] if indent is not None else line)
if not out:
    sys.exit("config.yml not found in the rendered ConfigMap")
print("\n".join(out))
'
}

"${helm}" lint "${chart}" --strict --values "${chart}/ci/default-values.yaml"

failed=0
for values in "${chart}"/ci/*.yaml; do
  name="$(basename "${values}" .yaml)"
  echo "=== ${name}"

  "${helm}" template ci "${chart}" --kube-version "${kube_version}" --values "${values}" > "${work_dir}/${name}.yaml"
  "${helm}" template ci "${chart}" --kube-version "${kube_version}" --values "${values}" --show-only templates/configmap.yaml \
    | extract_config > "${work_dir}/${name}-config.yml"

  # The entrypoint runs the command as the proxy user; the config's log
  # directories exist in the image, so the check can open its appenders.
  if docker run --rm \
      --volume "${work_dir}/${name}-config.yml:/check/config.yml:ro" \
      "${image}" \
      java -jar stroom-proxy-app-all.jar check /check/config.yml \
      > "${work_dir}/${name}-check.log" 2>&1; then
    echo "config OK"
  else
    echo "config INVALID:"
    grep -v '^\s*at \|^[0-9:,]* |-' "${work_dir}/${name}-check.log" | tail -30
    failed=1
  fi
done

# Boot test: "check" only validates the config's shape, so also start the
# proxy the way the pod does (non-root, generated keystore, the chart's
# volume layout) with the default values, which forward to a local file and
# need no AWS access. Expect a healthy health check, and an unauthenticated
# POST to be refused.
boot_test() {
  local config="$1" container="stroom-proxy-boot-test-$$" boot_dir="${work_dir}/boot"
  mkdir -p "${boot_dir}/config" "${boot_dir}/tls" "${boot_dir}/volume" "${boot_dir}/dfk"
  # The container runs as uid 1000, which may not be the host user.
  chmod 777 "${boot_dir}/tls" "${boot_dir}/volume" "${boot_dir}/dfk"
  cp "${config}" "${boot_dir}/config/config.yml"
  chmod 644 "${boot_dir}/config/config.yml"

  # Same command as the chart's tls init container.
  docker run --rm --user 1000:1000 \
    --volume "${boot_dir}/tls:/stroom-proxy/tls" \
    --entrypoint keytool "${image}" \
    -genkeypair -noprompt -alias stroom-proxy -keyalg RSA -keysize 2048 -validity 1 \
    -dname CN=boot-test -keystore /stroom-proxy/tls/server.p12 -storetype PKCS12 \
    -storepass stroom-proxy-ephemeral -keypass stroom-proxy-ephemeral > /dev/null

  docker run -d --name "${container}" --user 1000:1000 \
    --publish 127.0.0.1::8443 --publish 127.0.0.1::8091 \
    --env JAVA_OPTS=-Xmx1g \
    --volume "${boot_dir}/config:/stroom-proxy/config:ro" \
    --volume "${boot_dir}/tls:/stroom-proxy/tls:ro" \
    --volume "${boot_dir}/volume:/stroom-proxy/volume" \
    --volume "${boot_dir}/dfk:/stroom-proxy/data_feed_identities" \
    "${image}" > /dev/null

  local admin_port https_port health datafeed result=0
  admin_port="$(docker port "${container}" 8091/tcp | head -1 | sed 's/.*://')"
  https_port="$(docker port "${container}" 8443/tcp | head -1 | sed 's/.*://')"

  # The same path as the chart's probes (and so the load balancer's checks).
  local health_path
  health_path="$(sed -n 's/^ *path: "\{0,1\}\(\/proxyAdmin\/[^"]*\)"\{0,1\}$/\1/p' "${work_dir}/default-values.yaml" | head -1)"
  health="$(curl -s --retry 40 --retry-delay 3 --retry-all-errors -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${admin_port}${health_path}" || true)"
  # Host is a load balancer name, which the pod's certificate doesn't match:
  # this also checks the SNI host check is off.
  datafeed="$(curl -sk -o /dev/null -w '%{http_code}' -X POST -H 'Host: proxy.example.internal' -H 'Feed: BOOT-TEST' \
    --data 'test' "https://127.0.0.1:${https_port}/datafeed" || true)"

  if [ "${health}" = "200" ] && [ "${datafeed}" = "401" ]; then
    echo "boot OK (health ${health}, unauthenticated datafeed ${datafeed})"
  else
    echo "boot FAILED (health ${health}, unauthenticated datafeed ${datafeed}, expected 200 and 401):"
    docker logs "${container}" 2>&1 | grep -v '^\s*at ' | tail -40
    result=1
  fi
  docker rm -f "${container}" > /dev/null
  return "${result}"
}

echo "=== boot test (default-values)"
boot_test "${work_dir}/default-values-config.yml" || failed=1

exit "${failed}"
