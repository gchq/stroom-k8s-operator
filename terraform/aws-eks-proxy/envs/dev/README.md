# Dev environment: first apply and test checklist

The first real deployment, to prove the design on AWS (phase 4's "done
when", design section 16). Small instances, one NAT gateway, 1-day data
retention, throwaway test certificates.

## Before you start

* [ ] A dev AWS account and a role that can create VPC, EKS, IAM, KMS, S3,
      SQS, ELB, ACM and Route 53 resources.
* [ ] An S3 bucket for Terraform state (versioned, encrypted, private).
* [ ] Nothing for DNS or the server certificate: dev uses made-up names
      (`proxy.dev.test`, `mtls.proxy.dev.test`) and a server certificate from
      the test server CA, imported into ACM (`acm_imported`). With a real
      domain, use `acm_public` and `route53_zone_id` instead.
* [ ] An EC2 vCPU quota of at least 16 (Running On-Demand Standard
      instances): 10 for the nodes, 16 during a blue/green test. New accounts
      start at 5.
* [ ] The public IP of the machine that will run Terraform and the tests.
* [ ] Terraform 1.10+, the AWS CLI, kubectl, curl, openssl.
* [ ] Put your own values in git-ignored override files, so the committed
      files keep their `REPLACE_ME` placeholders. Terraform takes the later
      file's value, so these win:

      envs/dev/local-backend.hcl        bucket = "<state bucket>"
      envs/dev/local-10-infra.tfvars    api_allowed_cidrs
      envs/dev/local-20-platform.tfvars infra_state (with your bucket)
      envs/dev/local-30-stroom-proxy.tfvars
                                        infra_state, platform_state,
                                        allowed_ingress_cidrs, admin_cidrs

      Check every `REPLACE_ME` in the committed files is overridden:

      grep -rn REPLACE_ME envs/dev

* [ ] Make the test certificates (git-ignored, valid 30 days). Pass the host
      names as the third and fourth arguments if you change them in the
      tfvars:

      scripts/make-test-certs.sh envs/dev/test-certs

## Apply

Run from `terraform/aws-eks-proxy`, one stack at a time, checking each plan:

```sh
cd stacks/10-infra
terraform init -backend-config=../../envs/dev/backend-10-infra.hcl -backend-config=../../envs/dev/local-backend.hcl
terraform plan -var-file=../../envs/dev/10-infra.tfvars -var-file=../../envs/dev/local-10-infra.tfvars -out=dev.tfplan
terraform apply dev.tfplan
$(terraform output -raw kubeconfig_command)
kubectl get nodes -L topology.kubernetes.io/zone,workload,stroom-proxy/colour

cd ../20-platform
terraform init -backend-config=../../envs/dev/backend-20-platform.hcl -backend-config=../../envs/dev/local-backend.hcl
terraform plan -var-file=../../envs/dev/20-platform.tfvars -var-file=../../envs/dev/local-20-platform.tfvars -out=dev.tfplan
terraform apply dev.tfplan

cd ../30-stroom-proxy
terraform init -backend-config=../../envs/dev/backend-30-stroom-proxy.hcl -backend-config=../../envs/dev/local-backend.hcl
terraform plan -var-file=../../envs/dev/30-stroom-proxy.tfvars -var-file=../../envs/dev/local-30-stroom-proxy.tfvars -out=dev.tfplan
terraform apply dev.tfplan
terraform output endpoints
```

`route53_zone_id` is null, so nothing resolves the host names. Look up an
address of each NLB (`nlb_dns_name` in the `endpoints` output) and give curl
`--resolve`:

```sh
MTLS_IP=$(dig +short <mtls nlb_dns_name> | head -1)
PLAIN_IP=$(dig +short <plain nlb_dns_name> | head -1)
CURL_MTLS="curl --cacert test-certs/server-ca.pem --resolve mtls.proxy.dev.test:443:$MTLS_IP"
CURL_PLAIN="curl --cacert test-certs/server-ca.pem --resolve proxy.dev.test:443:$PLAIN_IP"
```

## Tests

Set `MTLS=https://mtls.proxy.dev.test` and `PLAIN=https://proxy.dev.test`,
and use `$CURL_MTLS` and `$CURL_PLAIN` (above) in place of `curl`. The
certificates are in `envs/dev/test-certs/`.

### Platform (10-infra, 20-platform)

* [ ] One proxy node per AZ (`stroom-proxy/colour=blue`), two system nodes.
* [ ] `kubectl -n amazon-cloudwatch get pods -o wide`: Fluent Bit on every node,
      proxy nodes included.
* [ ] `kubectl get storageclass`: `gp3` is the default.

### Proxy pods

* [ ] `kubectl -n stroom-proxy get pods`: 3 Ready, one per node and AZ.
* [ ] The readiness gate is satisfied (`kubectl -n stroom-proxy get pod <pod> -o jsonpath='{.status.conditions}'`).
* [ ] Each pod logged `Using configured proxy id: stroom-proxy-dev-stroom-proxy-blue-<n>`.

### mTLS endpoint

* [ ] Valid certificate: `curl --cert test-certs/client.pem --key test-certs/client.key -H 'Feed: TEST-EVENTS' --data-binary 'hello' $MTLS/datafeed` returns 200.
* [ ] No certificate: the TLS handshake fails.
* [ ] Certificate from the other CA (`rogue-client.*`): the TLS handshake fails.
* [ ] The receive log shows `RemoteDN=CN=test-sender,OU=dev,O=Stroom Test`
      (`kubectl -n stroom-proxy logs <pod> stroom-proxy | grep '^receive '`).
* [ ] **Open question (section 5.3)**: valid certificate plus a forged
      `-H 'X-Stroom-Mtls-Subject: CN=someone-else'`. The receive log must show
      the certificate's DN, not `someone-else`. If it shows `someone-else`,
      stop: the ALB is passing the client's header through, and the mTLS
      listener needs the same 403 rule as the plain one.

### Plain endpoint

* [ ] No credentials: 401.
* [ ] **F14 protection**: `-H 'X-Stroom-Mtls-Subject: CN=someone-else'` and no
      other credentials returns **403 from the ALB** (not 200 from the proxy).
      Repeat with `X-Amzn-Mtls-Clientcert-Subject` and `X-SSL-CLIENT-S-DN`.
* [ ] Data feed key: upload a DataFeedIdentities file to
      `s3://<receipt_config_bucket>/dfk/` (format: Stroom docs, "Data Feed
      Identities"); within `dfk_sync_interval_seconds` a request with
      `Authorization: Bearer <key>` returns 200. Delete the file: within the
      interval the same request returns 401.
* [ ] Token (if `TOKEN` and `openid` are set): a token from the IdP returns 200.

### Network isolation

* [ ] From a pod in another namespace, `curl -k https://<proxy pod IP>:8443/datafeed`
      times out (NetworkPolicy).
* [ ] The same from a pod in the `stroom-proxy` namespace also times out (the
      policy allows only the lb subnets).

### Data bucket

* [ ] Objects appear under `s3://<data_bucket>/<type>/<yyyy>/<mm>/<dd>/<feed>/<uuid>.zip`
      after the aggregation period (10 minutes by default).
* [ ] `aws s3api get-object-retention` on one shows `COMPLIANCE` and a
      retain-until date one day ahead.
* [ ] Deleting a version (`aws s3api delete-object --version-id ...`), even as
      an admin, is refused.
* [ ] A message for each object arrives on the `data_events_queue_url` queue.

### Sender addresses (open question, section 5.4)

* [ ] In the ALB access logs (if enabled) or VPC flow logs, check whether the
      ALB saw the senders' own addresses or the NLBs'. Either way traffic
      works; record which, so the ALB security group rules can be tightened.

### Logs and draining

* [ ] CloudWatch Logs `/aws/containerinsights/stroom-proxy-dev/application`
      has `receive` lines.
* [ ] `kubectl -n stroom-proxy delete pod stroom-proxy-blue-0` while sending
      requests in a loop: no errors except retried connection resets, and the
      replacement pod only gets traffic once it is healthy in the target
      group.

## Afterwards

Record the results, especially the two open questions, in the design doc
(section 15). To tear down, follow "Destroy" in the stack README: the data
bucket and its key are kept until you remove them from state; with 1-day
retention the bucket can be emptied and deleted a day after the last upload.
