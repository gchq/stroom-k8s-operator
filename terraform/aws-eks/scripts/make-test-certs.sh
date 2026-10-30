#!/usr/bin/env bash
#
# Makes throwaway certificates for testing the mTLS endpoint in a dev
# environment. Never use them anywhere real.
#
#   scripts/make-test-certs.sh <out-dir> [days] [hostname mtls-hostname]
#
# Writes to <out-dir> (git-ignored under envs/*/test-certs/):
#   client-ca.pem / client-ca.key     test CA: give client-ca.pem to Terraform
#                                     (client_ca_bundle_pem_file)
#   client.pem / client.key           a client certificate the CA signed:
#                                     should be accepted
#   rogue-ca.pem / rogue-client.*     a client certificate from another CA:
#                                     should be refused at the TLS handshake
#   server-ca.pem / server-ca.key     test CA for the ALB's server certificate:
#                                     clients use it with curl --cacert
#   server.pem / server.key           server certificate for both host names
#                                     (default proxy.dev.test and
#                                     mtls.proxy.dev.test), for
#                                     tls_certificate_source = "acm_imported"
#
# The client certificate's subject is CN=test-sender,OU=dev,O=Stroom Test.
# The ALB passes it to the proxy in RFC 2253 form, the form a
# CERTIFICATE_IDENTITY entry must use: CN=test-sender,OU=dev,O=Stroom Test

set -euo pipefail

out="${1:?usage: $0 <out-dir> [days]}"
days="${2:-30}"
hostname="${3:-proxy.dev.test}"
mtls_hostname="${4:-mtls.proxy.dev.test}"
mkdir -p "${out}"
chmod 700 "${out}"
cd "${out}"

make_ca() {
  local name="$1" cn="$2"
  openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "${name}.key" -out "${name}.pem" -days "${days}" \
    -subj "/O=Stroom Test/CN=${cn}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

make_client() {
  local name="$1" ca="$2" cn="$3"
  openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "${name}.key" -out "${name}.csr" \
    -subj "/O=Stroom Test/OU=dev/CN=${cn}" 2>/dev/null
  openssl x509 -req -in "${name}.csr" -CA "${ca}.pem" -CAkey "${ca}.key" \
    -CAcreateserial -out "${name}.pem" -days "${days}" \
    -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n') 2>/dev/null
  rm -f "${name}.csr"
}

make_server() {
  local name="$1" ca="$2"
  openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "${name}.key" -out "${name}.csr" \
    -subj "/O=Stroom Test/CN=${hostname}" 2>/dev/null
  openssl x509 -req -in "${name}.csr" -CA "${ca}.pem" -CAkey "${ca}.key" \
    -CAcreateserial -out "${name}.pem" -days "${days}" \
    -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,DNS:%s\n' "${hostname}" "${mtls_hostname}") 2>/dev/null
  rm -f "${name}.csr"
}

make_ca client-ca "Stroom Test Client CA"
make_client client client-ca test-sender

make_ca rogue-ca "Untrusted Test CA"
make_client rogue-client rogue-ca rogue-sender

# A separate CA, so trusting the server certificate doesn't mean trusting
# client certificates, and the reverse.
make_ca server-ca "Stroom Test Server CA"
make_server server server-ca

rm -f ./*.srl
chmod 600 ./*.key

echo "Test certificates in ${out} (valid ${days} days):"
openssl x509 -in client.pem -noout -subject -issuer -enddate
openssl x509 -in server.pem -noout -subject -ext subjectAltName
