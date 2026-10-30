# --- from 10-infra and 20-platform ---

variable "name" {
  description = "Name of the deployment (the 10-infra name). Prefixes AWS resources."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "aws_region" {
  description = "AWS region of the cluster, the data bucket and its queue (Stroom's S3 ingest supports one region)."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the cluster."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets, one per AZ: EFS mount targets."
  type        = list(string)
}

variable "lb_subnet_ids" {
  description = "Subnets for the ALB."
  type        = list(string)
}

variable "lb_subnet_cidrs" {
  description = "CIDRs of the lb subnets: the only sources, besides other Stroom pods and the proxy, allowed to reach Stroom's ports."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Security group shared by all nodes (and so pods, with the VPC CNI)."
  type        = string
}

variable "stroom_node_sets" {
  description = "Stroom node groups from 10-infra: the label selecting each node set's nodes, and its node count."
  type = map(object({
    node_label = object({ key = string, value = string })
    node_count = number
  }))
}

variable "stroom_node_taint" {
  description = "Taint on Stroom nodes (from 10-infra)."
  type        = object({ key = string, value = string, effect = string })
}

variable "storage_class_name" {
  description = "StorageClass for the nodes' data volumes (20-platform's gp3)."
  type        = string
}

variable "secrets_name_prefix" {
  description = "Secrets Manager prefix the External Secrets Operator may read (20-platform)."
  type        = string
}

variable "external_secrets_role_arn" {
  description = "IAM role of the External Secrets Operator (20-platform). Given read access to the RDS-managed master secret, which is outside secrets_name_prefix."
  type        = string
}

variable "internal_ca" {
  description = "The in-cluster CA from 20-platform: ClusterIssuer, ConfigMap name and key, and the namespace label that publishes it."
  type = object({
    cluster_issuer  = string
    configmap_name  = string
    configmap_key   = string
    namespace_label = object({ key = string, value = string })
  })
}

variable "tags" {
  description = "Tags added to every AWS resource."
  type        = map(string)
  default     = {}
}

# --- the database (modules/stroom-db) ---

variable "db" {
  description = "The database from modules/stroom-db, and the CA bundle that signs its certificate (PEM)."
  type = object({
    host                   = string
    port                   = number
    master_user_secret_arn = string
    app_user               = string
    app_user_secret_name   = string
    kms_key_arn            = string
    ca_bundle_pem          = string
  })
}

# --- Stroom ---

variable "namespace" {
  description = "Kubernetes namespace for Stroom."
  type        = string
  default     = "stroom"
}

variable "cluster_resource_name" {
  description = "Name of the StroomCluster resource. Stroom's service account and Secrets are named from it."
  type        = string
  default     = "stroom"
}

variable "node_name_prefix" {
  description = "Prefix of the Stroom node names: <prefix>-<node set>-<n>, e.g. stroom-prod-proc-0. Permanent: Stroom keys each node's index shards and jobs by its name."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$", var.node_name_prefix))
    error_message = "node_name_prefix must be 1-40 lower-case letters, digits and hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "stroom_image" {
  description = "Stroom image. The digest pins it; the tag is for people."
  type = object({
    repository = optional(string, "gchq/stroom")
    tag        = string
    digest     = optional(string)
  })

  validation {
    condition     = var.stroom_image.digest == null ? true : can(regex("^sha256:[0-9a-f]{64}$", var.stroom_image.digest))
    error_message = "stroom_image.digest must look like sha256:<64 hex digits>."
  }
}

variable "stopped" {
  description = "Stop every Stroom node (StatefulSets scaled to 0, each node drained first) without changing the counts: for version upgrades (design section 12)."
  type        = bool
  default     = false
}

variable "node_sets" {
  description = <<-EOT
    Stroom node sets. Keys are node set names and must match 10-infra's
    stroom_node_sets. Counts may only grow, and names are permanent (Stroom
    nodes own their index shards).

    count          : Stroom nodes (pods); at most the node set's node count in 10-infra.
    role           : Processing (all jobs, including the S3 ingest poll) or Frontend (UI and API).
    cpu            : CPU request and limit, in cores; leave room for the node's system pods.
    memory_gib     : memory request and limit.
    heap_gib       : Java heap; set as a whole percentage of memory_gib, so rounded up a little.
    data_volume_gb : gp3 data volume per node: index shards, analytic and Plan B state, logs.
    nvme           : sizeLimits of the directories on the node's NVMe (emptyDir), in GiB.
  EOT
  type = map(object({
    count          = number
    role           = string
    cpu            = number
    memory_gib     = number
    heap_gib       = number
    data_volume_gb = number
    nvme = optional(object({
      tmp_gib            = optional(number, 200)
      reference_data_gib = optional(number, 500)
      search_results_gib = optional(number, 200)
    }), {})
  }))

  validation {
    condition     = length(var.node_sets) > 0
    error_message = "node_sets needs at least one node set."
  }

  validation {
    condition     = alltrue([for k, s in var.node_sets : contains(["Processing", "Frontend"], s.role)])
    error_message = "Each node set's role must be Processing or Frontend."
  }

  validation {
    condition     = anytrue([for s in values(var.node_sets) : s.role == "Processing"]) && anytrue([for s in values(var.node_sets) : s.role == "Frontend"])
    error_message = "node_sets needs a Processing node set (jobs and S3 ingest) and a Frontend one (the UI behind the ALB)."
  }

  validation {
    condition     = alltrue([for s in values(var.node_sets) : s.count >= 1 && floor(s.count) == s.count])
    error_message = "Each node set's count must be a whole number, at least 1."
  }

  validation {
    condition     = alltrue([for s in values(var.node_sets) : s.heap_gib > 0 && s.heap_gib <= s.memory_gib * 0.75])
    error_message = "Each node set's heap_gib must be at most three quarters of memory_gib, leaving room for direct memory, LMDB's page cache and the OS."
  }
}

variable "extra_jvm_opts" {
  description = "Extra JVM options for every node, e.g. [\"-XX:+UseZGC\"]. The heap comes from node_sets."
  type        = list(string)
  default     = []
}

variable "stream_volume" {
  description = "Shared stream volume (design 5.3). Only efs for now. throughput_mode: elastic (recommended) or bursting."
  type = object({
    type            = optional(string, "efs")
    throughput_mode = optional(string, "elastic")
    backup          = optional(bool, true)
  })
  default = {}

  validation {
    condition     = var.stream_volume.type == "efs"
    error_message = "stream_volume.type must be efs; a writable S3 volume is a later test (design 5.3)."
  }
}

# --- authentication (design section 8) ---

variable "idp" {
  description = <<-EOT
    The external identity provider. The app registration (or client) is made
    outside Terraform.

    type               : entra, keycloak or cognito.
    tenant_id          : Entra tenant, for the discovery URL.
    discovery_url      : OpenID configuration URL; derived for entra.
    client_id          : the app registration's client ID.
    client_secret_name : Secrets Manager name of the client secret, relative to
                         secrets_name_prefix.
    first_admin        : the first administrator's IdP identity (Entra object
                         ID, or the uniqueIdentityClaim value), and display name.
  EOT
  type = object({
    type               = optional(string, "entra")
    tenant_id          = optional(string)
    discovery_url      = optional(string)
    client_id          = string
    client_secret_name = string
    first_admin = object({
      subject      = string
      display_name = string
    })
  })

  validation {
    condition     = contains(["entra", "keycloak", "cognito"], var.idp.type)
    error_message = "idp.type must be entra, keycloak or cognito."
  }

  validation {
    condition     = var.idp.type == "entra" ? var.idp.tenant_id != null || var.idp.discovery_url != null : var.idp.discovery_url != null
    error_message = "idp needs tenant_id (entra) or discovery_url."
  }
}

# --- ingest from the data bucket (design section 7) ---

variable "ingest" {
  description = "The data bucket Stroom ingests from, its event queue and DLQ, its KMS key, and when its objects expire (null = never)."
  type = object({
    bucket            = string
    queue_url         = string
    queue_arn         = string
    dlq_url           = string
    dlq_arn           = string
    kms_key_arn       = optional(string)
    expire_after_days = optional(number)
  })
}

variable "raw_data_retention_days" {
  description = "The longest Stroom data retention rule for raw streams. The bucket must keep its objects at least this long, as Stroom's raw streams are the bucket's objects (design 7.3)."
  type        = number
}

# --- access (design section 9) ---

variable "hostname" {
  description = "Host name of the Stroom UI and API, e.g. stroom.example.internal."
  type        = string
}

variable "allowed_ingress_cidrs" {
  description = "Networks allowed to reach the ALB (users and API clients)."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_ingress_cidrs needs at least one IPv4 CIDR."
  }
}

variable "route53_zone_id" {
  description = "Route 53 zone for the host name's alias record (and DNS validation with acm_public). null = manage DNS elsewhere."
  type        = string
  default     = null
}

variable "tls_certificate_source" {
  description = "Server certificate on the ALB: acm_private_ca, acm_public, acm_existing or acm_imported, as for the proxy."
  type        = string
  default     = "acm_private_ca"

  validation {
    condition     = contains(["acm_private_ca", "acm_public", "acm_existing", "acm_imported"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be acm_private_ca, acm_public, acm_existing or acm_imported."
  }
}

variable "private_ca_arn" {
  description = "AWS Private CA for acm_private_ca."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ACM certificate for the host name, for acm_existing."
  type        = string
  default     = null
}

variable "imported_certificate" {
  description = "PEM certificate, private key and optional chain, imported into ACM for acm_imported. The key is kept in Terraform state: dev and test certificates only."
  type = object({
    certificate_pem       = string
    private_key_pem       = string
    certificate_chain_pem = optional(string)
  })
  default   = null
  sensitive = true
}

variable "alb_ssl_policy" {
  description = "TLS policy of the ALB's listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
}

variable "alb_idle_timeout" {
  description = "ALB idle timeout in seconds: the longest UI request without data (long searches, downloads)."
  type        = number
  default     = 300
}

variable "alb_access_logs_bucket" {
  description = "S3 bucket for ALB access logs. null = off."
  type        = string
  default     = null
}

variable "proxy_namespace" {
  description = "Namespace of a Stroom-Proxy in the same cluster, allowed to reach Stroom for receipt rules (design 8.1). null = none."
  type        = string
  default     = null
}

variable "proxy_api_key_secret_name" {
  description = "Secrets Manager name, relative to secrets_name_prefix, the bootstrap Job writes the proxy's Stroom API key to (design 8.1). null = no proxy user or key."
  type        = string
  default     = null
}
