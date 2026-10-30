# Inputs of this stack only. variables.tf mirrors modules/stroom-proxy and is
# regenerated from it, so stack-only inputs live here.

variable "client_ca_bundle_pem_file" {
  description = "Path to the client CA bundle PEM, relative to where Terraform runs (e.g. \"../../envs/dev/test-certs/client-ca.pem\"). Overrides auth.client_ca_bundle_pem; tfvars files can't read files themselves."
  type        = string
  default     = null
}

variable "imported_certificate_files" {
  description = "Paths to a PEM server certificate, its private key and optional chain, relative to where Terraform runs. Overrides imported_certificate (for tls_certificate_source = \"acm_imported\"), e.g. the test certificates from scripts/make-test-certs.sh."
  type = object({
    certificate       = string
    private_key       = string
    certificate_chain = optional(string)
  })
  default = null
}
