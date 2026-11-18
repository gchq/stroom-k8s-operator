package e2e

import (
	"fmt"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const statefulSet = "statefulset/stroom-e2e-node-node"

// operatorUpgradeSpecs tests upgrading the operator from the previous release, with a Stroom cluster running
func operatorUpgradeSpecs() {
	const namespace = "stroom-e2e-upgrade"
	pods := stroomPodNames("e2e", "node", stroomNodeCount())
	values := keycloakClusterValues(operatorDatabase, namespace)
	values["LOG_SENDER"] = disabledLogSender

	BeforeAll(func() {
		By("installing operator " + previousRelease)
		removeOperator()
		deployPreviousRelease()

		deployKeycloakAndDatabase(operatorDatabase, namespace, values)
		applyTestData(namespace, "stroom-cluster.yaml", values)
	})

	It("should run Stroom with the previous release", func() {
		Expect(operatorImage()).To(Equal(previousRepository + ":" + previousRelease))
		for _, pod := range pods {
			waitForCondition(namespace, "pod/"+pod, "condition=Ready", stroomStartTimeout)
		}
	})

	It("should update the database server, then roll the nodes, draining each, when the operator is upgraded", func() {
		const dbPod = "stroom-e2e-db-0"
		uids := podUids(namespace, append([]string{dbPod}, pods...))
		drains := map[string]int{}
		for _, pod := range pods {
			drains[pod] = drainCount(namespace, pod)
		}
		revision := mustKubectl("get", statefulSet, "-n", namespace, "-o", "jsonpath={.status.updateRevision}")

		By("upgrading the operator")
		deployOperator()
		Expect(operatorImage()).To(Equal(operatorRepository + ":" + operatorTag))

		// This release changes the database server's pod template, and the nodes' (the probes and security settings).
		// The database server is updated first, as the nodes need it to drain.
		Eventually(func() string {
			output, _ := kubectl("get", "pod", "-n", namespace, dbPod, "-o", "jsonpath={.metadata.uid}")
			return output
		}, defaultTimeout, 5*time.Second).ShouldNot(Or(BeEmpty(), Equal(uids[dbPod])), "the database server should be replaced")
		waitForCondition(namespace, "pod/"+dbPod, "condition=Ready", defaultTimeout)
		dbStarted := mustKubectl("get", "pod", "-n", namespace, dbPod, "-o", "jsonpath={.metadata.creationTimestamp}")

		Eventually(func() string {
			return mustKubectl("get", statefulSet, "-n", namespace, "-o", "jsonpath={.status.updateRevision}")
		}, 2*time.Minute, 5*time.Second).ShouldNot(Equal(revision))
		mustKubectl("rollout", "status", statefulSet, "-n", namespace, "--timeout=30m")
		for _, pod := range pods {
			waitForCondition(namespace, "pod/"+pod, "condition=Ready", stroomStartTimeout)
			Expect(podUids(namespace, []string{pod})[pod]).ToNot(Equal(uids[pod]), "%v should have been replaced", pod)
			// RFC 3339 timestamps in UTC sort as strings
			nodeStarted := mustKubectl("get", "pod", "-n", namespace, pod, "-o", "jsonpath={.metadata.creationTimestamp}")
			Expect(nodeStarted >= dbStarted).To(BeTrue(), "%v (%v) should have been replaced after the database server (%v)", pod, nodeStarted, dbStarted)
			Expect(drainCount(namespace, pod)).To(BeNumerically(">", drains[pod]), "%v should have drained:\n%v", pod,
				lifecycleLogs(namespace, pod))
		}
	})

	It("should give the nodes the new health check filters", func() {
		// The StroomCluster has no allow or deny lists stored, as the previous release had none, so the defaults apply
		for _, pod := range pods {
			paths := mustKubectl("get", "pod", "-n", namespace, pod, "-o",
				`jsonpath={.spec.containers[?(@.name=="stroom-node")].livenessProbe.httpGet.path} {.spec.containers[?(@.name=="stroom-node")].readinessProbe.httpGet.path}`)
			Expect(paths).To(Equal("/stroomAdmin/filteredhealthcheck?allow=deadlocks /stroomAdmin/filteredhealthcheck?deny=" + externalIdpCheck))
		}
	})

	It("should keep the StroomCluster's stored probe timings", func() {
		timings := mustKubectl("get", "stroomcluster", "e2e", "-n", namespace, "-o",
			"jsonpath={.spec.nodeSets[0].startupProbeTimings.failureThreshold} {.spec.nodeSets[0].livenessProbeTimings.failureThreshold}")
		Expect(timings).To(Equal(values["STARTUP_FAILURE_THRESHOLD"] + " 10"))
	})

	It("should record the Stroom version the nodes already run, rather than migrating", func() {
		image := mustKubectl("get", "stroomcluster", "e2e", "-n", namespace, "-o", "jsonpath={.status.migratedImage}")
		Expect(image).To(Equal("gchq/stroom:" + stroomTag))
		status, reason, _ := migrationCondition(namespace)
		Expect(status + " " + reason).To(Equal("True Succeeded"))

		logs := mustKubectl("logs", "-n", operatorNamespace, operatorDeployment)
		Expect(logs).To(ContainSubstring("Recorded the image the nodes already run as the migrated image"))
		for _, line := range strings.Split(logs, "\n") {
			if strings.Contains(line, namespace) {
				Expect(line).ToNot(ContainSubstring("Creating database migration Job"))
			}
		}
	})
}

// bootstrapLockSpecs tests the database migration waiting on the Stroom bootstrap lock, which Stroom holds while it
// upgrades the database, then upgrades Stroom. The lock is held by the test for a fixed time, so the wait is
// predictable. The migration Job, rather than the nodes, waits on it, so the nodes start once the database is ready.
func bootstrapLockSpecs() {
	const (
		namespace = "stroom-e2e-lock"
		// Without the lock wait allowance, the startup probe allows 10 + 9 x 10 seconds, which the lock is held for
		// longer than. The allowance adds 300 seconds for the second node, so 30 more failures.
		startupInitialDelay      = "10"
		startupFailureThreshold  = "9"
		lockWaitAllowance        = "300"
		expectedFailureThreshold = "39"
		lockHoldSeconds          = 150
	)
	// The allowance is for each node after the first, so at least two are needed
	nodes := max(2, stroomNodeCount())
	pods := stroomPodNames("e2e", "node", nodes)
	values := keycloakClusterValues(operatorDatabase, namespace)
	values["PROVISIONING_STROOM_TAG"] = previousStroomTag
	values["STROOM_TAG"] = previousStroomTag
	values["STROOM_NODES"] = fmt.Sprint(nodes)
	values["STARTUP_INITIAL_DELAY"] = startupInitialDelay
	values["STARTUP_FAILURE_THRESHOLD"] = startupFailureThreshold
	values["LOCK_WAIT_ALLOWANCE"] = "lockWaitAllowanceSeconds: " + lockWaitAllowance

	BeforeAll(func() {
		deployKeycloakAndDatabase(operatorDatabase, namespace, values)
	})

	It("should migrate the database once the bootstrap lock is free, then start the nodes without restarting them", func() {
		By("making Stroom upgrade the database, while the lock is held")
		// The lock is released no earlier than this. Truncated to the second, as the condition's time is
		lockReleased := time.Now().UTC().Add(lockHoldSeconds * time.Second).Format(time.RFC3339)
		holdBootstrapLock(namespace, lockHoldSeconds)
		applyTestData(namespace, "stroom-cluster.yaml", values)

		Eventually(func() string {
			output, _ := kubectl("get", "stroomcluster", "e2e", "-n", namespace, "-o", "jsonpath={.status.migratedImage}")
			return output
		}, stroomStartTimeout, 5*time.Second).Should(Equal("gchq/stroom:" + previousStroomTag))
		status, reason, migrated := migrationCondition(namespace)
		Expect(status + " " + reason).To(Equal("True Succeeded"))
		Expect(migrated >= lockReleased).To(BeTrue(), "the migration (%v) should have waited for the lock to be released (%v)", migrated, lockReleased)

		for _, pod := range pods {
			waitForCondition(namespace, "pod/"+pod, "condition=Ready", stroomStartTimeout)
			nodeStarted := mustKubectl("get", "pod", "-n", namespace, pod, "-o", "jsonpath={.metadata.creationTimestamp}")
			Expect(nodeStarted >= migrated).To(BeTrue(), "%v (%v) should have started after the migration finished (%v)", pod, nodeStarted, migrated)
			// The allowance still applies, for a node that waits on the lock for another reason
			threshold := mustKubectl("get", "pod", "-n", namespace, pod, "-o",
				`jsonpath={.spec.containers[?(@.name=="stroom-node")].startupProbe.failureThreshold}`)
			Expect(threshold).To(Equal(expectedFailureThreshold), pod)
			Expect(podRestartCount(namespace, pod)).To(Equal(0), "%v should not have been restarted", pod)
		}
	})

	It("should migrate the database in a Job, then upgrade Stroom one node at a time, draining each node", func() {
		target := "gchq/stroom:" + stroomTag
		drains := map[string]int{}
		for _, pod := range pods {
			drains[pod] = drainCount(namespace, pod)
		}

		// RFC 3339 timestamps in UTC sort as strings. This one is truncated to the second, so it's no later than the patch
		patched := time.Now().UTC().Format(time.RFC3339)
		mustKubectl("patch", "stroomcluster", "e2e", "-n", namespace, "--type=json",
			"-p", fmt.Sprintf(`[{"op": "replace", "path": "/spec/image/tag", "value": %q}]`, stroomTag))

		By("migrating the database before any node changes version")
		Eventually(func() string {
			return mustKubectl("get", "stroomcluster", "e2e", "-n", namespace, "-o", "jsonpath={.status.migratedImage}")
		}, stroomStartTimeout, 5*time.Second).Should(Equal(target))
		status, reason, migrated := migrationCondition(namespace)
		Expect(status + " " + reason).To(Equal("True Succeeded"))
		Expect(migrated >= patched).To(BeTrue(), "the migration (%v) should have finished after the upgrade began (%v)", migrated, patched)
		Expect(mustKubectl("get", "jobs", "-n", namespace, "-o", "name")).ToNot(ContainSubstring("-cli-migrate-"),
			"the migration Job should be removed once it succeeds")

		mustKubectl("rollout", "status", statefulSet, "-n", namespace, "--timeout=30m")
		for _, pod := range pods {
			waitForCondition(namespace, "pod/"+pod, "condition=Ready", stroomStartTimeout)
			image := mustKubectl("get", "pod", pod, "-n", namespace, "-o",
				`jsonpath={.spec.containers[?(@.name=="stroom-node")].image}`)
			Expect(image).To(Equal(target))
			nodeStarted := mustKubectl("get", "pod", "-n", namespace, pod, "-o", "jsonpath={.metadata.creationTimestamp}")
			Expect(nodeStarted >= migrated).To(BeTrue(), "%v (%v) should have started after the migration finished (%v)", pod, nodeStarted, migrated)
			Expect(drainCount(namespace, pod)).To(BeNumerically(">", drains[pod]), "%v should have drained before upgrading", pod)
		}
		Expect(mysqlAsRoot(namespace, "e2e", rootPassword(namespace, "e2e"), "SELECT build_version FROM stroom.build_version")).
			To(ContainSubstring(strings.TrimPrefix(stroomTag, "v")))
	})
}

// migrationCondition returns the status, reason and last transition time of the e2e StroomCluster's DatabaseMigrated
// condition
func migrationCondition(namespace string) (string, string, string) {
	output := mustKubectl("get", "stroomcluster", "e2e", "-n", namespace, "-o", `jsonpath=`+
		`{.status.conditions[?(@.type=="DatabaseMigrated")].status} `+
		`{.status.conditions[?(@.type=="DatabaseMigrated")].reason} `+
		`{.status.conditions[?(@.type=="DatabaseMigrated")].lastTransitionTime}`)
	fields := strings.Fields(output)
	ExpectWithOffset(1, fields).To(HaveLen(3), "the DatabaseMigrated condition: %q", output)
	return fields[0], fields[1], fields[2]
}

// offlineUpgradeSpecs tests upgrading Stroom with the Offline upgrade strategy: every node is drained and stopped
// before the database is migrated, then the nodes start on the new version
func offlineUpgradeSpecs() {
	const namespace = "stroom-e2e-offline"
	pods := stroomPodNames("e2e", "node", stroomNodeCount())
	values := keycloakClusterValues(operatorDatabase, namespace)
	values["PROVISIONING_STROOM_TAG"] = previousStroomTag
	values["STROOM_TAG"] = previousStroomTag
	values["UPGRADE_STRATEGY"] = "upgradeStrategy: Offline"

	BeforeAll(func() {
		deployKeycloakAndDatabase(operatorDatabase, namespace, values)
		applyTestData(namespace, "stroom-cluster.yaml", values)
	})

	It("should run Stroom", func() {
		for _, pod := range pods {
			waitForCondition(namespace, "pod/"+pod, "condition=Ready", stroomStartTimeout)
		}
	})

	It("should stop every node, draining each, before migrating the database, then start them on the new version", func() {
		target := "gchq/stroom:" + stroomTag
		drains := map[string]int{}
		for _, pod := range pods {
			drains[pod] = drainCount(namespace, pod)
		}

		patched := time.Now().UTC().Format(time.RFC3339)
		mustKubectl("patch", "stroomcluster", "e2e", "-n", namespace, "--type=json",
			"-p", fmt.Sprintf(`[{"op": "replace", "path": "/spec/image/tag", "value": %q}]`, stroomTag))

		By("migrating the database with no node running")
		// Each check reads the migration Job, then the node pods. A node created before the Job, and still there
		// after it was created, ran during the migration. Starting Stroom takes far longer than a check, so the Job
		// is seen.
		var sawMigration bool
		var nodesDuringMigration []string
		Eventually(func() string {
			jobs, _ := kubectl("get", "jobs", "-n", namespace, "-o",
				`jsonpath={range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}`)
			for _, line := range strings.Split(jobs, "\n") {
				fields := strings.Fields(line)
				if len(fields) != 2 || !strings.Contains(fields[0], "-cli-migrate-") {
					continue
				}
				sawMigration = true
				nodes, _ := kubectl("get", "pods", "-n", namespace, "-l", "stroom/cluster=e2e,stroom/nodeSet", "-o",
					`jsonpath={range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}`)
				for _, node := range strings.Split(nodes, "\n") {
					if nodeFields := strings.Fields(node); len(nodeFields) == 2 && nodeFields[1] < fields[1] {
						nodesDuringMigration = append(nodesDuringMigration, nodeFields[0])
					}
				}
			}
			output, _ := kubectl("get", "stroomcluster", "e2e", "-n", namespace, "-o", "jsonpath={.status.migratedImage}")
			return output
		}, stroomStartTimeout, 2*time.Second).Should(Equal(target))
		Expect(sawMigration).To(BeTrue(), "the migration Job should have been seen")
		Expect(nodesDuringMigration).To(BeEmpty(), "no node should run while the database is migrated")

		status, reason, migrated := migrationCondition(namespace)
		Expect(status + " " + reason).To(Equal("True Succeeded"))
		Expect(migrated >= patched).To(BeTrue(), "the migration (%v) should have finished after the upgrade began (%v)", migrated, patched)

		mustKubectl("rollout", "status", statefulSet, "-n", namespace, "--timeout=30m")
		for _, pod := range pods {
			waitForCondition(namespace, "pod/"+pod, "condition=Ready", stroomStartTimeout)
			image := mustKubectl("get", "pod", pod, "-n", namespace, "-o",
				`jsonpath={.spec.containers[?(@.name=="stroom-node")].image}`)
			Expect(image).To(Equal(target))
			// The pre-stop log is kept on the node's volume, which is kept while the nodes are stopped
			Expect(drainCount(namespace, pod)).To(BeNumerically(">", drains[pod]), "%v should have drained before stopping", pod)
		}
	})
}

// holdBootstrapLock makes Stroom upgrade the database when it next starts, by changing the build version recorded in
// it, then holds the lock Stroom needs to do so for a number of seconds
func holdBootstrapLock(namespace string, seconds int) {
	password := rootPassword(namespace, "e2e")
	mysqlAsRoot(namespace, "e2e", password, "UPDATE stroom.build_version SET build_version = 'e2e-forced-upgrade'")

	// Run the session in the background, so it outlives this command
	mustKubectl("exec", "-n", namespace, "stroom-e2e-db-0", "-c", "mysql", "--", "sh", "-c", fmt.Sprintf(
		`MYSQL_PWD='%v' nohup mysql -uroot -e "BEGIN; SELECT * FROM stroom.build_version FOR UPDATE; DO SLEEP(%v); COMMIT;" > /tmp/bootstrap-lock.log 2>&1 &`,
		password, seconds))
	Eventually(func() string {
		return strings.TrimSpace(mysqlAsRoot(namespace, "e2e", password,
			"SELECT COUNT(*) FROM performance_schema.data_locks WHERE OBJECT_SCHEMA = 'stroom' AND OBJECT_NAME = 'build_version'"))
	}, time.Minute, 2*time.Second).ShouldNot(Equal("0"), "the bootstrap lock should be held")
}

// lifecycleLogs returns a node's lifecycle script logs, which are kept on its volume, for diagnosing a failed spec
func lifecycleLogs(namespace string, pod string) string {
	output, err := execInPod(namespace, pod, "stroom-node", "ls -la /stroom/logs/k8s; tail -n 30 /stroom/logs/k8s/*.log")
	if err != nil {
		return fmt.Sprintf("%v: %v", err, output)
	}
	return output
}

// drainCount returns how many times a node's pre-stop hook has drained it
func drainCount(namespace string, pod string) int {
	output, _ := execInPod(namespace, pod, "stroom-node", "cat /stroom/logs/k8s/pre-stop.log 2>/dev/null")
	return strings.Count(output, "All tasks drained")
}

// operatorImage returns the image the operator is running
func operatorImage() string {
	return mustKubectl("get", operatorDeployment, "-n", operatorNamespace, "-o",
		`jsonpath={.spec.template.spec.containers[?(@.name=="manager")].image}`)
}

// podUids returns the UID of each pod, which changes when a pod is replaced
func podUids(namespace string, pods []string) map[string]string {
	uids := map[string]string{}
	for _, pod := range pods {
		uids[pod] = mustKubectl("get", "pod", "-n", namespace, pod, "-o", "jsonpath={.metadata.uid}")
	}
	return uids
}
