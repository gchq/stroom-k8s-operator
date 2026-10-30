# modules/stroom and modules/stroom-db on their own: the rendered config.yml
# and StroomCluster, and the plan-time checks. Plan-only, against mocked
# providers.
#
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
mock_provider "kubernetes" {}

# The proxy key's secret as it is once created: its ARN is one of the bootstrap
# Job's settings, so its name is known in plans after the first
override_resource {
  target          = aws_secretsmanager_secret.proxy_api_key
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:stroom/test/stroom-proxy-api-key-AbCdEf"
  }
}
mock_provider "time" {}

variables {
  name                      = "stroom-test"
  cluster_name              = "stroom-test"
  aws_region                = "eu-west-2"
  vpc_id                    = "vpc-0123456789abcdef0"
  private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
  lb_subnet_ids             = ["subnet-d", "subnet-e", "subnet-f"]
  lb_subnet_cidrs           = ["10.40.208.0/26", "10.40.208.64/26", "10.40.208.128/26"]
  node_security_group_id    = "sg-nodes"
  storage_class_name        = "gp3"
  secrets_name_prefix       = "stroom/test/"
  external_secrets_role_arn = "arn:aws:iam::123456789012:role/stroom-test-eso-abc"
  stroom_node_taint         = { key = "workload", value = "stroom", effect = "NoSchedule" }
  stroom_node_sets = {
    proc = { node_label = { key = "stroom/node-set", value = "proc" }, node_count = 2 }
    ui   = { node_label = { key = "stroom/node-set", value = "ui" }, node_count = 1 }
  }
  internal_ca = {
    cluster_issuer  = "stroom-internal-ca"
    configmap_name  = "stroom-internal-ca"
    configmap_key   = "ca.crt"
    namespace_label = { key = "stroom.gchq.github.io/internal-ca", value = "true" }
  }
  db = {
    host                   = "stroom.abc.eu-west-2.rds.amazonaws.com"
    port                   = 3306
    master_user_secret_arn = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:rds!db-abc"
    app_user               = "stroomuser"
    app_user_secret_name   = "stroom/test/db-stroomuser"
    app_user_secret_arn    = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:stroom/test/db-stroomuser-AbCdEf"
    kms_key_arn            = "arn:aws:kms:eu-west-2:123456789012:key/db"
    ca_bundle_pem          = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  }

  node_name_prefix = "stroom-test"
  stroom_image     = { tag = "v7.14.0", digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  node_sets = {
    proc = { count = 2, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
    ui   = { count = 1, role = "Frontend", cpu = 14, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
  }
  idp = {
    tenant_id          = "00000000-0000-0000-0000-000000000000"
    client_id          = "11111111-1111-1111-1111-111111111111"
    client_secret_name = "stroom-oidc-client-secret"
    first_admin        = { subject = "22222222-2222-2222-2222-222222222222", display_name = "First Admin" }
  }
  ingest = {
    bucket            = "stroom-test-data"
    queue_url         = "https://sqs.eu-west-2.amazonaws.com/123456789012/stroom-test-data-events"
    queue_arn         = "arn:aws:sqs:eu-west-2:123456789012:stroom-test-data-events"
    dlq_url           = "https://sqs.eu-west-2.amazonaws.com/123456789012/stroom-test-data-events-dlq"
    dlq_arn           = "arn:aws:sqs:eu-west-2:123456789012:stroom-test-data-events-dlq"
    kms_key_arn       = "arn:aws:kms:eu-west-2:123456789012:key/data"
    expire_after_days = 91
  }
  raw_data_retention_days   = 60
  hostname                  = "stroom.example.internal"
  allowed_ingress_cidrs     = ["10.0.0.0/8"]
  private_ca_arn            = "arn:aws:acm-pca:eu-west-2:123456789012:certificate-authority/abc"
  proxy_namespace           = "stroom-proxy"
  proxy_api_key_secret_name = "stroom-proxy-api-key"
}

run "renders_the_stroom_config" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  assert {
    condition = (
      yamldecode(output.stroom_config).appConfig.receive.s3Event.sqs.queueUrl == "https://sqs.eu-west-2.amazonaws.com/123456789012/stroom-test-data-events" &&
      yamldecode(output.stroom_config).appConfig.receive.s3Event.sqs.deadLetterQueueUrl == "https://sqs.eu-west-2.amazonaws.com/123456789012/stroom-test-data-events-dlq" &&
      yamldecode(output.stroom_config).appConfig.receive.s3Event.sqs.awsRegionName == "eu-west-2"
    )
    error_message = "Expected the S3 event queue, DLQ and region in config.yml."
  }

  assert {
    condition = (
      yamldecode(output.stroom_config).appConfig.security.authentication.openId.identityProviderType == "EXTERNAL_IDP" &&
      yamldecode(output.stroom_config).appConfig.security.authentication.openId.openIdConfigurationEndpoint == "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0/.well-known/openid-configuration" &&
      yamldecode(output.stroom_config).appConfig.security.authentication.openId.uniqueIdentityClaim == "oid" &&
      contains(yamldecode(output.stroom_config).appConfig.security.authentication.openId.allowedAudiences, "api://11111111-1111-1111-1111-111111111111")
    )
    error_message = "Expected the Entra preset: discovery URL from the tenant, oid as the identity claim (so the pre-created admin matches), both audiences."
  }

  assert {
    condition     = yamldecode(output.stroom_config).appConfig.security.authentication.openId.clientSecret == "$${STROOM_OPERATOR_OPENID_CLIENT_SECRET}"
    error_message = "Expected the client secret as Stroom's own placeholder, not a value."
  }

  assert {
    condition = (
      yamldecode(output.stroom_config).appConfig.nodeUri.scheme == "https" &&
      yamldecode(output.stroom_config).jerseyClients.STROOM.tls.trustStorePath == "/stroom/pki/tls/truststore.p12" &&
      !contains(keys(yamldecode(output.stroom_config).jerseyClients), "DEFAULT")
    )
    error_message = "Expected HTTPS cluster calls trusting the in-cluster CA, for the STROOM client only."
  }

  assert {
    condition = (
      yamldecode(output.stroom_config).appConfig.data.filesystemVolume.defaultStreamVolumePaths == ["/stroom/stream"] &&
      yamldecode(output.stroom_config).appConfig.volumes.defaultIndexVolumeGroupPaths == ["/stroom/index"]
    )
    error_message = "Expected the stream volume on EFS and the index volumes on the data volume."
  }

  assert {
    condition     = yamldecode(output.stroom_config).appConfig.node.name == "$${STROOM_NODE:-node1a}" && yamldecode(output.stroom_config).server.applicationConnectors[1].port == "$${STROOM_APP_HTTPS_PORT:-8443}"
    error_message = "Expected Stroom's own $${...} placeholders kept for Stroom to substitute."
  }
}

run "renders_the_stroom_cluster" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  assert {
    condition     = [for s in output.stroom_cluster_spec.nodeSets : s.name] == ["proc", "ui"]
    error_message = "Expected the node sets in name order."
  }

  assert {
    condition = (
      output.stroom_cluster_spec.nodeSets[0].memoryOptions.maxPercentage == 27 &&
      output.stroom_cluster_spec.nodeSets[1].memoryOptions.maxPercentage == 54
    )
    error_message = "Expected the heap as a whole percentage, rounded up (64 of 240 GiB: 27%; 64 of 120: 54%)."
  }

  assert {
    condition = (
      output.stroom_cluster_spec.nodeSets[0].nodeSelector["stroom/node-set"] == "proc" &&
      output.stroom_cluster_spec.nodeSets[0].tolerations[0].value == "stroom" &&
      output.stroom_cluster_spec.nodeSets[0].podSecurityContext.runAsUser == 1000 &&
      output.stroom_cluster_spec.nodeSets[0].directories.referenceData.emptyDir.sizeLimit == "500Gi"
    )
    error_message = "Expected each node set on its own nodes, as uid 1000, with reference data on NVMe."
  }

  assert {
    condition = (
      output.stroom_cluster_spec.image.tag == "v7.14.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" &&
      output.stroom_cluster_spec.nodeNamePrefix == "stroom-test" &&
      output.stroom_cluster_spec.preventNodeRemoval == true &&
      output.stroom_cluster_spec.identityProviderType == "EXTERNAL_IDP"
    )
    error_message = "Expected the pinned image, node name prefix, removal guard and external IdP."
  }

  assert {
    condition = (
      output.stroom_cluster_spec.databaseServerRef.serverAddress.tls.mode == "VerifyIdentity" &&
      output.stroom_cluster_spec.databaseServerRef.serverAddress.tls.caCertificates.configMapName == "rds-ca" &&
      output.stroom_cluster_spec.https.tlsSecretName == "stroom-tls"
    )
    error_message = "Expected verified TLS to RDS and HTTPS on the nodes."
  }

  assert {
    condition     = output.stroom_cluster_spec.extraVolumeMounts[0].mountPath == "/stroom/stream" && output.stroom_cluster_spec.nodeSets[0].extraVolumeMounts[0].subPath == "index"
    error_message = "Expected the EFS stream volume and the index directory mounted."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.proxy_api_key) == 1 && output.frontend_service == "stroom-test-ui-http.stroom.svc.cluster.local"
    error_message = "Expected the proxy's API key secret and the Frontend Service."
  }

  assert {
    condition     = aws_lb_target_group.ui.stickiness[0].cookie_name == "STROOM_SESSION_ID" && aws_lb_target_group.ui.protocol == "HTTPS"
    error_message = "Expected sticky sessions and HTTPS to the pods."
  }

  assert {
    condition = alltrue([for c in aws_lb_listener_rule.refuse.condition : alltrue([for p in c.path_pattern : (
      contains(p.values, "/datafeed*") && contains(p.values, "/stroom/noauth/datafeed*") &&
      length(p.values) <= 5 && length(regexall("[*?]", join("", p.values))) <= 5
    )])])
    error_message = "Expected Stroom's datafeed paths refused at the ALB, within the ALB's limits of 5 values and 5 wildcards per rule."
  }

  assert {
    condition = (
      output.stroom_cluster_spec.nodeSets[0].affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[1] == { key = "stroom/nodeSet", operator = "Exists" } &&
      !can(output.stroom_cluster_spec.nodeSets[0].affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution) &&
      output.stroom_cluster_spec.nodeSets[0].topologySpreadConstraints[1].topologyKey == "kubernetes.io/hostname" &&
      output.stroom_cluster_spec.nodeSets[0].topologySpreadConstraints[1].whenUnsatisfiable == "DoNotSchedule"
    )
    error_message = "Expected one pod per node from a hostname spread, and no required anti-affinity, which the operator's API key Job would copy and so never fit next to a Stroom pod."
  }

  assert {
    condition = (
      output.stroom_cluster_spec.nodeSets[0].podAnnotations["stroom.gchq.github.io/db-password-version"] == "1" &&
      # Read from the Certificate once it exists, so unknown in this plan
      contains(keys(output.stroom_cluster_spec.nodeSets[1].podAnnotations), "stroom.gchq.github.io/tls-revision") &&
      output.stroom_cluster_spec.nodeSets[1].podAnnotations["instrumentation.opentelemetry.io/inject-java"] == "false"
    )
    error_message = "Expected the password generation and certificate revision on every node set's pods, so a change restarts them."
  }

  assert {
    condition     = kubernetes_manifest.tls_certificate.manifest.spec.renewBefore == "2160h" && kubernetes_manifest.tls_certificate.manifest.spec.duration == "8760h"
    error_message = "Expected the certificate renewed 90 days before it expires, leaving time for an apply to restart the nodes."
  }
}

run "network_policy" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  # The bootstrap Job reaches Stroom's API, on 8443 only
  assert {
    condition = length([
      for i in kubernetes_network_policy_v1.stroom.spec[0].ingress : i
      if anytrue([for f in i.from : anytrue([for s in f.pod_selector : s.match_labels == tomap({ "app.kubernetes.io/name" = "stroom-bootstrap" })])])
      && [for p in i.ports : p.port] == ["8443"]
      && length(i.from) == 1
    ]) == 1
    error_message = "Expected an ingress rule letting the bootstrap Job's pods (and only them) reach 8443."
  }

  assert {
    condition     = kubernetes_job_v1.bootstrap[0].spec[0].template[0].metadata[0].labels == tomap({ "app.kubernetes.io/name" = "stroom-bootstrap" })
    error_message = "Expected the bootstrap Job's pods to carry the label the NetworkPolicy admits."
  }

  # Nothing else new: the ALB's subnets and Stroom's pods on 8443 and 8081, the proxy on 8443
  assert {
    condition = (
      length(kubernetes_network_policy_v1.stroom.spec[0].ingress) == 3 &&
      [for p in kubernetes_network_policy_v1.stroom.spec[0].ingress[2].ports : p.port] == ["8443"] &&
      kubernetes_network_policy_v1.stroom.spec[0].ingress[2].from[0].namespace_selector[0].match_labels == tomap({ "kubernetes.io/metadata.name" = "stroom-proxy" })
    )
    error_message = "Expected three ingress rules: ALB and Stroom pods, the bootstrap Job, and the proxy on 8443."
  }
}

run "refuses_direct_data_receipt" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  assert {
    condition = (
      yamldecode(output.stroom_config).appConfig.receive.enabledAuthenticationTypes == ["DATA_FEED_KEY"] &&
      yamldecode(output.stroom_config).appConfig.receive.authenticationRequired == true &&
      !contains(keys(yamldecode(output.stroom_config).appConfig.receive), "receiptCheckMode")
    )
    error_message = "Expected Stroom to refuse posts to /datafeed (only data feed keys, of which there are none), and to leave receiptCheckMode, which S3 ingest uses, alone."
  }
}

run "external_secrets_role" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  assert {
    condition     = aws_iam_role.external_secrets.name_prefix == "stroom-test-steso-"
    error_message = "Expected the role named <cluster_name>-*, the only roles the External Secrets controller may assume."
  }

  assert {
    condition = (
      data.aws_iam_policy_document.external_secrets_trust.statement[0].actions == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      one(data.aws_iam_policy_document.external_secrets_trust.statement[0].principals).identifiers == toset(["arn:aws:iam::123456789012:role/stroom-test-eso-abc"])
    )
    error_message = "Expected the role to trust the External Secrets controller's role only."
  }

  assert {
    condition = (
      data.aws_iam_policy_document.external_secrets.statement[0].actions == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]) &&
      toset(data.aws_iam_policy_document.external_secrets.statement[0].resources) == toset([
        "arn:aws:secretsmanager:eu-west-2:123456789012:secret:stroom/test/db-stroomuser-AbCdEf",
        "arn:aws:secretsmanager:eu-west-2:123456789012:secret:rds!db-abc",
        "arn:aws:secretsmanager:eu-west-2:123456789012:secret:stroom/test/stroom-oidc-client-secret-??????",
      ])
    )
    error_message = "Expected Stroom's secrets only: the database user's, the RDS master secret and the OIDC client secret (not the proxy's key)."
  }

  assert {
    condition = (
      toset(data.aws_iam_policy_document.external_secrets.statement[1].resources) == toset(["arn:aws:kms:eu-west-2:123456789012:key/db"]) &&
      toset(one(data.aws_iam_policy_document.external_secrets.statement[1].condition).values) == toset(["secretsmanager.eu-west-2.amazonaws.com"])
    )
    error_message = "Expected kms:Decrypt on the database key, through Secrets Manager only."
  }
}

# The longest deployment name (29 characters, 10-infra): IAM role name prefixes
# are limited to 38 characters, RDS identifier prefixes to 37. Mocked providers
# don't check lengths, so the test does.
run "longest_name_fits_aws_limits" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    name         = "abcdefghij-klmnopqrst-uvwxyz1"
    cluster_name = "abcdefghij-klmnopqrst-uvwxyz1"
  }

  assert {
    condition = alltrue([for p in concat(
      [aws_iam_role.stroom.name_prefix, aws_iam_role.bootstrap.name_prefix, aws_iam_role.external_secrets.name_prefix],
      aws_iam_role.proxy_key_renewal[*].name_prefix,
    ) : length(p) <= 38]) && length(var.name) == 29
    error_message = "Expected every IAM role name prefix within 38 characters for a 29-character name."
  }

  assert {
    condition     = length(aws_lb.stroom.name) <= 32 && length(aws_lb_target_group.ui.name) <= 32
    error_message = "Expected the ALB and target group names within 32 characters."
  }
}

run "longest_name_fits_aws_limits_db" {
  command = plan

  module {
    source = "../../modules/stroom-db"
  }

  variables {
    name                      = "abcdefghij-klmnopqrst-uvwxyz1"
    subnet_ids                = ["subnet-a", "subnet-b", "subnet-c"]
    client_security_group_ids = ["sg-nodes"]
  }

  assert {
    condition     = length(aws_db_instance.db.identifier_prefix) <= 37 && length(aws_db_parameter_group.db.name_prefix) <= 100 && length(aws_db_subnet_group.db.name_prefix) <= 100
    error_message = "Expected the RDS identifier prefix within 37 characters for a 29-character name."
  }
}

run "rejects_node_set_name_not_a_dns_label" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    node_sets = {
      Proc = { count = 2, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
      ui   = { count = 1, role = "Frontend", cpu = 14, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
    }
  }

  expect_failures = [var.node_sets]
}

run "rejects_statefulset_name_too_long" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    # 40 + 1 + 12 = 53 characters
    node_name_prefix = "stroom-test-abcdefghijklmnopqrstuvwxyz12"
    node_sets = {
      proc         = { count = 2, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
      ui-frontends = { count = 1, role = "Frontend", cpu = 14, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
    }
    stroom_node_sets = {
      proc         = { node_label = { key = "stroom/node-set", value = "proc" }, node_count = 2 }
      ui-frontends = { node_label = { key = "stroom/node-set", value = "ui-frontends" }, node_count = 1 }
    }
  }

  expect_failures = [var.node_sets]
}

run "rejects_external_secrets_role_outside_cluster_name" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    name = "other"
  }

  expect_failures = [terraform_data.check_role_names]
}

run "bootstrap_and_db_init_inputs" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  assert {
    condition     = output.bootstrap_job != null && startswith(output.bootstrap_job, "stroom-bootstrap-")
    error_message = "Expected the bootstrap Job while the cluster runs."
  }

  assert {
    condition = (
      kubernetes_manifest.proxy_key_renewal[0].manifest.spec.suspend == false &&
      kubernetes_manifest.proxy_key_renewal[0].manifest.spec.jobTemplate.spec.template.spec.serviceAccountName == "stroom-proxy-key-renewal" &&
      contains([for e in kubernetes_manifest.proxy_key_renewal[0].manifest.spec.jobTemplate.spec.template.spec.containers[0].env : e.name], "RENEW_BEFORE_DAYS") &&
      data.aws_iam_policy_document.proxy_key_renewal[0].statement[0].actions == toset(["secretsmanager:ListSecretVersionIds", "secretsmanager:PutSecretValue"])
    )
    error_message = "Expected the proxy key renewal CronJob, with its own service account, allowed only to list and write the key's versions."
  }
}

# A change to config.yml alone doesn't run the bootstrap again
run "bootstrap_ignores_config" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    ingest = {
      bucket            = "stroom-test-data"
      queue_url         = "https://sqs.eu-west-2.amazonaws.com/123456789012/other-events"
      queue_arn         = "arn:aws:sqs:eu-west-2:123456789012:other-events"
      dlq_url           = "https://sqs.eu-west-2.amazonaws.com/123456789012/other-events-dlq"
      dlq_arn           = "arn:aws:sqs:eu-west-2:123456789012:other-events-dlq"
      kms_key_arn       = "arn:aws:kms:eu-west-2:123456789012:key/data"
      expire_after_days = 91
    }
  }

  assert {
    condition     = output.bootstrap_job == run.bootstrap_and_db_init_inputs.bootstrap_job
    error_message = "Expected the same bootstrap Job when only config.yml changes."
  }
}

# A new node, or a new image, runs it again
run "bootstrap_reruns_for_nodes_and_image" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    stroom_image = { tag = "v7.14.1" }
  }

  assert {
    condition     = output.bootstrap_job != run.bootstrap_and_db_init_inputs.bootstrap_job
    error_message = "Expected a new bootstrap Job for a new image."
  }
}

# Stopped for an upgrade: no bootstrap Job waiting for an API with no pods, and
# no key renewal against a database the new version hasn't migrated yet
run "stopped_has_no_bootstrap" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    stopped = true
  }

  assert {
    condition     = length(kubernetes_job_v1.bootstrap) == 0 && output.bootstrap_job == null
    error_message = "Expected no bootstrap Job while the cluster is stopped."
  }

  assert {
    condition     = kubernetes_manifest.proxy_key_renewal[0].manifest.spec.suspend == true
    error_message = "Expected the key renewal CronJob suspended while the cluster is stopped."
  }

  assert {
    condition     = output.stroom_cluster_spec.stopped == true
    error_message = "Expected the StroomCluster stopped."
  }
}

# A new database password: the init Job runs again, and the nodes restart
run "db_password_rotation" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    db = {
      host                      = "stroom.abc.eu-west-2.rds.amazonaws.com"
      port                      = 3306
      master_user_secret_arn    = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:rds!db-abc"
      app_user                  = "stroomuser"
      app_user_secret_name      = "stroom/test/db-stroomuser"
      app_user_secret_arn       = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:stroom/test/db-stroomuser-AbCdEf"
      app_user_password_version = 2
      kms_key_arn               = "arn:aws:kms:eu-west-2:123456789012:key/db"
      ca_bundle_pem             = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    }
  }

  assert {
    condition     = output.db_init_job != run.bootstrap_and_db_init_inputs.db_init_job
    error_message = "Expected a new database init Job for a new password."
  }

  assert {
    condition     = strcontains(kubernetes_job_v1.db_init.spec[0].template[0].spec[0].container[0].command[2], "RETAIN CURRENT PASSWORD")
    error_message = "Expected the old password kept as the secondary one, so running nodes can connect while they restart."
  }

  assert {
    condition     = kubernetes_manifest.db_secret.manifest.spec.target.template.data["password-version"] == "2"
    error_message = "Expected the generation in the Secret, for the init Job to wait for."
  }

  assert {
    condition     = output.bootstrap_job == run.bootstrap_and_db_init_inputs.bootstrap_job
    error_message = "Expected the bootstrap Job unchanged by a new password."
  }

  assert {
    condition     = alltrue([for s in output.stroom_cluster_spec.nodeSets : s.podAnnotations["stroom.gchq.github.io/db-password-version"] == "2"])
    error_message = "Expected the nodes restarted with the new password."
  }
}

run "no_proxy_no_key" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    proxy_namespace           = null
    proxy_api_key_secret_name = null
  }

  assert {
    condition     = length(aws_secretsmanager_secret.proxy_api_key) == 0
    error_message = "Expected no proxy API key without a proxy."
  }
}

run "keycloak_preset" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    idp = {
      type               = "keycloak"
      discovery_url      = "https://keycloak.example.internal/realms/stroom/.well-known/openid-configuration"
      client_id          = "stroom"
      client_secret_name = "stroom-oidc-client-secret"
      first_admin        = { subject = "abc", display_name = "First Admin" }
    }
  }

  assert {
    condition     = yamldecode(output.stroom_config).appConfig.security.authentication.openId.uniqueIdentityClaim == "sub"
    error_message = "Expected sub as the identity claim for Keycloak."
  }
}

run "rejects_retention_longer_than_bucket_expiry" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    raw_data_retention_days = 91
  }

  expect_failures = [terraform_data.check_retention]
}

run "rejects_more_pods_than_nodes" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    node_sets = {
      proc = { count = 3, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
      ui   = { count = 1, role = "Frontend", cpu = 14, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
    }
  }

  expect_failures = [terraform_data.check_node_counts]
}

run "rejects_node_set_without_node_groups" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    node_sets = {
      proc  = { count = 2, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
      front = { count = 1, role = "Frontend", cpu = 14, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
    }
  }

  expect_failures = [terraform_data.check_node_groups]
}

run "rejects_no_frontend" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    node_sets = {
      proc = { count = 2, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
    }
  }

  expect_failures = [var.node_sets]
}

run "rejects_heap_too_big" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    node_sets = {
      proc = { count = 2, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 200, data_volume_gb = 1000 }
      ui   = { count = 1, role = "Frontend", cpu = 14, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
    }
  }

  expect_failures = [var.node_sets]
}

run "rejects_private_ca_without_arn" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    private_ca_arn = null
  }

  expect_failures = [terraform_data.check_tls_source]
}

run "rejects_keycloak_without_discovery_url" {
  command = plan

  module {
    source = "../../modules/stroom"
  }

  variables {
    idp = {
      type               = "keycloak"
      client_id          = "stroom"
      client_secret_name = "stroom-oidc-client-secret"
      first_admin        = { subject = "abc", display_name = "First Admin" }
    }
  }

  expect_failures = [var.idp]
}

# --- modules/stroom-db ---

run "database_plan" {
  command = plan

  module {
    source = "../../modules/stroom-db"
  }

  variables {
    subnet_ids                = ["subnet-a", "subnet-b", "subnet-c"]
    client_security_group_ids = ["sg-nodes"]
  }

  assert {
    condition = (
      aws_db_instance.db.engine == "mysql" && aws_db_instance.db.engine_version == "8.4" &&
      aws_db_instance.db.manage_master_user_password == true &&
      aws_db_instance.db.storage_encrypted == true && aws_db_instance.db.publicly_accessible == false &&
      aws_db_instance.db.skip_final_snapshot == false && aws_db_instance.db.deletion_protection == true
    )
    error_message = "Expected an encrypted, private MySQL 8.4 instance with an RDS-managed password, a final snapshot and deletion protection."
  }

  assert {
    condition     = one([for p in aws_db_parameter_group.db.parameter : p.value if p.name == "require_secure_transport"]) == "1"
    error_message = "Expected TLS required."
  }

  assert {
    condition     = aws_db_parameter_group.db.family == "mysql8.4"
    error_message = "Expected the mysql8.4 parameter group family."
  }

  assert {
    condition     = aws_secretsmanager_secret.app_user.name == "stroom/test/db-stroomuser"
    error_message = "Expected the Stroom user's password under the secrets prefix."
  }
}

run "database_rejects_other_versions" {
  command = plan

  module {
    source = "../../modules/stroom-db"
  }

  variables {
    subnet_ids                = ["subnet-a", "subnet-b", "subnet-c"]
    client_security_group_ids = ["sg-nodes"]
    database                  = { engine_version = "8.0" }
  }

  expect_failures = [var.database]
}
