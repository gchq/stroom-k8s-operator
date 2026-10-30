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
    condition     = anytrue([for c in aws_lb_listener_rule.refuse.condition : anytrue([for p in c.path_pattern : contains(p.values, "*clustercall.rpc*")])])
    error_message = "Expected cluster calls refused at the ALB."
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

  expect_failures = [terraform_data.input_checks]
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

  expect_failures = [terraform_data.input_checks]
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

  expect_failures = [terraform_data.input_checks]
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

  expect_failures = [terraform_data.input_checks]
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
