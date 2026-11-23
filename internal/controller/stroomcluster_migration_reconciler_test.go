package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/events"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("StroomCluster database migration", func() {

	var (
		ctx        = context.Background()
		testScheme *runtime.Scheme
		reconciler *StroomClusterReconciler
		recorder   *events.FakeRecorder
		cluster    *stroomv1.StroomCluster
		dbInfo     *DatabaseConnectionInfo
		key        = types.NamespacedName{Namespace: "stroom", Name: "dev"}
	)

	BeforeEach(func() {
		testScheme = runtime.NewScheme()
		Expect(clientgoscheme.AddToScheme(testScheme)).To(Succeed())
		Expect(stroomv1.AddToScheme(testScheme)).To(Succeed())

		cluster = &stroomv1.StroomCluster{
			ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace},
			Spec: stroomv1.StroomClusterSpec{
				Image:    stroomv1.Image{Repository: "gchq/stroom", Tag: "v7.13.2"},
				NodeSets: []stroomv1.NodeSet{{Name: "data", Count: 2}},
			},
		}
		dbInfo = goldenDatabaseConnectionInfo("db")
		recorder = events.NewFakeRecorder(10)
	})

	// start creates the fake API server holding the cluster, and anything else the operator should find there
	start := func(objects ...client.Object) {
		fakeClient := fake.NewClientBuilder().WithScheme(testScheme).
			WithObjects(append(objects, cluster)...).
			WithStatusSubresource(cluster, &batchv1.Job{}).Build()
		reconciler = &StroomClusterReconciler{Client: fakeClient, Scheme: testScheme, Recorder: recorder}
	}

	// ensure runs one migration check against the latest copy of the cluster, as a reconcile would
	ensure := func() (bool, error) {
		Expect(reconciler.Get(ctx, key, cluster)).To(Succeed())
		ready, _, err := reconciler.ensureDatabaseMigrated(ctx, cluster, dbInfo)
		return ready, err
	}

	// nodeStatefulSet is the StatefulSet of a cluster whose nodes already run the image
	nodeStatefulSet := func(image string) *appsv1.StatefulSet {
		replicas := int32(2)
		return &appsv1.StatefulSet{
			ObjectMeta: metav1.ObjectMeta{Name: cluster.GetNodeSetName(&cluster.Spec.NodeSets[0]), Namespace: key.Namespace},
			Spec: appsv1.StatefulSetSpec{
				Replicas: &replicas,
				Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{
					Containers: []corev1.Container{{Name: StroomNodeContainerName, Image: image}},
				}},
			},
		}
	}

	migrationJob := func() *batchv1.Job {
		job := &batchv1.Job{}
		name := types.NamespacedName{Namespace: key.Namespace, Name: cluster.GetCliJobName(migrationJobSuffix(cluster.Spec.Image.String()))}
		Expect(reconciler.Get(ctx, name, job)).To(Succeed())
		return job
	}

	jobs := func() []batchv1.Job {
		list := batchv1.JobList{}
		Expect(reconciler.List(ctx, &list, client.InNamespace(key.Namespace))).To(Succeed())
		return list.Items
	}

	// finishJob sets the Job's status as the Job controller would once its pod exits
	finishJob := func(job *batchv1.Job, conditionType batchv1.JobConditionType) {
		job.Status.Conditions = append(job.Status.Conditions, batchv1.JobCondition{
			Type: conditionType, Status: corev1.ConditionTrue, LastTransitionTime: metav1.Now(),
		})
		Expect(reconciler.Status().Update(ctx, job)).To(Succeed())
	}

	condition := func() *metav1.Condition {
		return meta.FindStatusCondition(cluster.Status.Conditions, stroomv1.ConditionDatabaseMigrated)
	}

	It("should record the image an existing cluster's nodes run, rather than migrating", func() {
		start(nodeStatefulSet("gchq/stroom:v7.13.2"))

		Expect(ensure()).To(BeTrue())
		Expect(cluster.Status.MigratedImage).To(Equal("gchq/stroom:v7.13.2"))
		Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonSucceeded))
		Expect(jobs()).To(BeEmpty())
	})

	It("should migrate an existing cluster whose nodes run an older version", func() {
		start(nodeStatefulSet("gchq/stroom:v7.13.1"))

		Expect(ensure()).To(BeFalse())
		Expect(cluster.Status.MigratedImage).To(Equal("gchq/stroom:v7.13.1"))
		Expect(migrationJob().Spec.Template.Spec.Containers[0].Image).To(Equal("gchq/stroom:v7.13.2"))
	})

	It("should create the schema on a fresh install, in a Job that's never retried or cut short", func() {
		start()

		Expect(ensure()).To(BeFalse())
		Expect(cluster.Status.MigratedImage).To(BeEmpty())
		Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonRunning))

		job := migrationJob()
		Expect(*job.Spec.BackoffLimit).To(BeZero())
		Expect(job.Spec.ActiveDeadlineSeconds).To(BeNil())
		Expect(job.Spec.TTLSecondsAfterFinished).To(BeNil())
		container := job.Spec.Template.Spec.Containers[0]
		Expect(container.Name).To(Equal(MigrationJobContainerName))
		Expect(container.Image).To(Equal("gchq/stroom:v7.13.2"))
		Expect(container.Args).To(Equal([]string{"bash", "-c", "cd /stroom && ./start.sh migrate"}))
		Expect(container.Env).To(ContainElement(corev1.EnvVar{Name: "JAVA_OPTS", Value: cliJobDefaultJavaOpts}))
	})

	It("should give the Job the cluster's migration settings", func() {
		deadline := int64(7200)
		cluster.Spec.Migration = stroomv1.MigrationSettings{
			ActiveDeadlineSeconds: &deadline,
			JavaOpts:              "-Xmx4g",
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("5Gi")},
			},
		}
		start()

		Expect(ensure()).To(BeFalse())
		job := migrationJob()
		Expect(*job.Spec.ActiveDeadlineSeconds).To(Equal(deadline))
		container := job.Spec.Template.Spec.Containers[0]
		Expect(container.Env).To(ContainElement(corev1.EnvVar{Name: "JAVA_OPTS", Value: "-Xmx4g"}))
		Expect(container.Resources).To(Equal(cluster.Spec.Migration.Resources))
	})

	It("should record a successful migration, remove its Job and release the nodes", func() {
		start()
		Expect(ensure()).To(BeFalse())

		finishJob(migrationJob(), batchv1.JobComplete)
		Expect(ensure()).To(BeTrue())
		Expect(cluster.Status.MigratedImage).To(Equal("gchq/stroom:v7.13.2"))
		Expect(condition().Status).To(Equal(metav1.ConditionTrue))
		Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonSucceeded))
		Expect(jobs()).To(BeEmpty())

		By("checking again, without migrating again")
		Expect(ensure()).To(BeTrue())
		Expect(jobs()).To(BeEmpty())
	})

	// annotate sets one of the cluster's annotations, or removes it if the value is empty
	annotate := func(name, value string) {
		Expect(reconciler.Get(ctx, key, cluster)).To(Succeed())
		if cluster.Annotations == nil {
			cluster.Annotations = map[string]string{}
		}
		if value == "" {
			delete(cluster.Annotations, name)
		} else {
			cluster.Annotations[name] = value
		}
		Expect(reconciler.Update(ctx, cluster)).To(Succeed())
	}

	Context("when the migration fails", func() {
		// failMigration runs the migration, and fails it
		failMigration := func() {
			Expect(ensure()).To(BeFalse())
			finishJob(migrationJob(), batchv1.JobFailed)
			Expect(ensure()).To(BeFalse())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonFailed))
		}

		It("should hold the nodes, keep the Job for its logs, and report the failure once", func() {
			start(nodeStatefulSet("gchq/stroom:v7.13.1"))
			failMigration()

			Expect(condition().Message).To(ContainSubstring("The nodes stay on gchq/stroom:v7.13.1"))
			Expect(recorder.Events).To(Receive(ContainSubstring("MigrationFailed")))

			By("checking again, without retrying or reporting it again")
			Expect(ensure()).To(BeFalse())
			Expect(recorder.Events).ToNot(Receive())
			Expect(jobs()).To(HaveLen(1))
			Expect(getJobFinishedCondition(migrationJob()).Type).To(Equal(batchv1.JobFailed))
		})

		It("should retry once the retry annotation is set, and need a new value to retry again", func() {
			start()
			failMigration()

			annotate(stroomv1.RetryMigrationAnnotation, "1")
			Expect(ensure()).To(BeFalse())
			Expect(jobs()).To(BeEmpty())

			Expect(ensure()).To(BeFalse())
			Expect(getJobFinishedCondition(migrationJob())).To(BeNil())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonRunning))

			By("failing again, with the same annotation value")
			finishJob(migrationJob(), batchv1.JobFailed)
			Expect(ensure()).To(BeFalse())
			Expect(ensure()).To(BeFalse())
			Expect(getJobFinishedCondition(migrationJob()).Type).To(Equal(batchv1.JobFailed))
		})

		It("should not retry for a request made before the failure was reported", func() {
			start()
			Expect(ensure()).To(BeFalse())
			annotate(stroomv1.RetryMigrationAnnotation, "1")

			finishJob(migrationJob(), batchv1.JobFailed)
			Expect(ensure()).To(BeFalse())
			Expect(ensure()).To(BeFalse())
			Expect(getJobFinishedCondition(migrationJob()).Type).To(Equal(batchv1.JobFailed))
		})

		It("should not retry when the annotation is removed", func() {
			cluster.Annotations = map[string]string{stroomv1.RetryMigrationAnnotation: "1"}
			start()
			failMigration()

			annotate(stroomv1.RetryMigrationAnnotation, "")
			Expect(ensure()).To(BeFalse())
			Expect(getJobFinishedCondition(migrationJob()).Type).To(Equal(batchv1.JobFailed))
		})
	})

	Context("when the version goes down", func() {
		It("should refuse to downgrade", func() {
			start(nodeStatefulSet("gchq/stroom:v7.13.3"))

			Expect(ensure()).To(BeFalse())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonDowngradeBlocked))
			Expect(recorder.Events).To(Receive(ContainSubstring("DowngradeBlocked")))
			Expect(jobs()).To(BeEmpty())
		})

		It("should downgrade when the allow-downgrade annotation is set", func() {
			cluster.Annotations = map[string]string{stroomv1.AllowDowngradeAnnotation: "true"}
			start(nodeStatefulSet("gchq/stroom:v7.13.3"))

			Expect(ensure()).To(BeFalse())
			Expect(migrationJob().Spec.Template.Spec.Containers[0].Image).To(Equal("gchq/stroom:v7.13.2"))
		})

		It("should warn, then migrate, when the versions can't be compared", func() {
			cluster.Spec.Image.Tag = "latest"
			start(nodeStatefulSet("gchq/stroom:v7.13.1"))

			Expect(ensure()).To(BeFalse())
			Expect(recorder.Events).To(Receive(ContainSubstring("MigrationVersionUnknown")))
			Expect(migrationJob().Spec.Template.Spec.Containers[0].Image).To(Equal("gchq/stroom:latest"))
		})
	})

	// setImageTag changes the Stroom version the cluster asks for, as editing the StroomCluster would
	setImageTag := func(tag string) {
		Expect(reconciler.Get(ctx, key, cluster)).To(Succeed())
		cluster.Spec.Image.Tag = tag
		Expect(reconciler.Update(ctx, cluster)).To(Succeed())
	}

	Context("with the Offline upgrade strategy", func() {
		var (
			nodePod *corev1.Pod
			nodePvc *corev1.PersistentVolumeClaim
		)

		BeforeEach(func() {
			cluster.Spec.UpgradeStrategy = stroomv1.OfflineUpgrade
			cluster.Spec.VolumeClaimDeletePolicy = stroomv1.DeleteOnScaledownOnlyPolicy
			nodeSet := &cluster.Spec.NodeSets[0]
			nodePod = &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
				Name: cluster.GetNodeSetName(nodeSet) + "-0", Namespace: key.Namespace,
				Labels: cluster.GetNodeSetSelectorLabels(nodeSet),
			}}
			nodePvc = &corev1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{
				Name: StroomNodePvcName + "-" + cluster.GetNodeSetName(nodeSet) + "-0", Namespace: key.Namespace,
			}}
		})

		It("should stop the nodes on their old image, keeping their data, and migrate once they've gone", func() {
			start(nodeStatefulSet("gchq/stroom:v7.13.1"), nodePod, nodePvc)

			Expect(ensure()).To(BeFalse())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonPending))
			Expect(jobs()).To(BeEmpty())
			statefulSet := &appsv1.StatefulSet{}
			Expect(reconciler.Get(ctx, client.ObjectKeyFromObject(nodeStatefulSet("")), statefulSet)).To(Succeed())
			Expect(*statefulSet.Spec.Replicas).To(BeZero())
			Expect(statefulSet.Spec.Template.Spec.Containers[0].Image).To(Equal("gchq/stroom:v7.13.1"))

			By("waiting while a node is still draining")
			Expect(ensure()).To(BeFalse())
			Expect(jobs()).To(BeEmpty())

			By("migrating once the last node has gone")
			Expect(reconciler.Delete(ctx, nodePod)).To(Succeed())
			Expect(ensure()).To(BeFalse())
			Expect(migrationJob().Spec.Template.Spec.Containers[0].Image).To(Equal("gchq/stroom:v7.13.2"))
			Expect(reconciler.Get(ctx, client.ObjectKeyFromObject(nodePvc), &corev1.PersistentVolumeClaim{})).To(Succeed())
		})

		It("should not wait for the CLI Jobs' pods, which aren't nodes", func() {
			jobPod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
				Name: "stroom-dev-cli-api-key-abcde", Namespace: key.Namespace, Labels: cluster.GetLabels(),
			}}
			start(nodeStatefulSet("gchq/stroom:v7.13.1"), jobPod)

			Expect(ensure()).To(BeFalse())
			Expect(jobs()).To(HaveLen(1))
		})

		It("should not stop the nodes of a fresh install, which has none", func() {
			start()

			Expect(ensure()).To(BeFalse())
			Expect(jobs()).To(HaveLen(1))
		})
	})

	It("should keep the nodes running during an Online upgrade", func() {
		cluster.Spec.UpgradeStrategy = stroomv1.OnlineUpgrade
		start(nodeStatefulSet("gchq/stroom:v7.13.1"))

		Expect(ensure()).To(BeFalse())
		Expect(jobs()).To(HaveLen(1))
		statefulSet := &appsv1.StatefulSet{}
		Expect(reconciler.Get(ctx, client.ObjectKeyFromObject(nodeStatefulSet("")), statefulSet)).To(Succeed())
		Expect(*statefulSet.Spec.Replicas).To(Equal(int32(2)))
	})

	Context("when the image changes during a migration", func() {
		It("should let the earlier migration finish, then migrate to the new image", func() {
			start(nodeStatefulSet("gchq/stroom:v7.13.1"))
			Expect(ensure()).To(BeFalse())
			earlier := migrationJob()

			setImageTag("v7.13.3")
			Expect(ensure()).To(BeFalse())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonPending))
			Expect(jobs()).To(HaveLen(1))

			finishJob(earlier, batchv1.JobComplete)
			Expect(ensure()).To(BeFalse())
			Expect(cluster.Status.MigratedImage).To(Equal("gchq/stroom:v7.13.2"))
			Expect(jobs()).To(HaveLen(1))
			Expect(migrationJob().Spec.Template.Spec.Containers[0].Image).To(Equal("gchq/stroom:v7.13.3"))
		})

		It("should block going back to the old version once the earlier migration has finished", func() {
			start(nodeStatefulSet("gchq/stroom:v7.13.1"))
			Expect(ensure()).To(BeFalse())
			earlier := migrationJob()

			setImageTag("v7.13.1")
			Expect(ensure()).To(BeFalse())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonPending))

			finishJob(earlier, batchv1.JobComplete)
			Expect(ensure()).To(BeFalse())
			Expect(cluster.Status.MigratedImage).To(Equal("gchq/stroom:v7.13.2"))
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonDowngradeBlocked))
			Expect(jobs()).To(BeEmpty())
		})
	})

	Context("with the skip-migration annotation", func() {
		BeforeEach(func() {
			cluster.Annotations = map[string]string{stroomv1.SkipMigrationAnnotation: "true"}
		})

		It("should record the image as migrated without a Job, and keep reporting the skip", func() {
			start()

			Expect(ensure()).To(BeTrue())
			Expect(cluster.Status.MigratedImage).To(Equal("gchq/stroom:v7.13.2"))
			Expect(condition().Status).To(Equal(metav1.ConditionTrue))
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonSkipped))
			Expect(recorder.Events).To(Receive(ContainSubstring("MigrationSkipped")))
			Expect(jobs()).To(BeEmpty())

			By("checking again")
			Expect(ensure()).To(BeTrue())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonSkipped))
			Expect(recorder.Events).ToNot(Receive())
		})

		It("should remove a failed migration's Job, and skip it", func() {
			cluster.Annotations = nil
			start()
			Expect(ensure()).To(BeFalse())
			finishJob(migrationJob(), batchv1.JobFailed)
			Expect(ensure()).To(BeFalse())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonFailed))

			annotate(stroomv1.SkipMigrationAnnotation, "true")
			Expect(ensure()).To(BeTrue())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonSkipped))
			Expect(jobs()).To(BeEmpty())
		})

		It("should wait for a running migration to finish before skipping it", func() {
			cluster.Annotations = nil
			start()
			Expect(ensure()).To(BeFalse())

			annotate(stroomv1.SkipMigrationAnnotation, "true")
			Expect(ensure()).To(BeFalse())
			Expect(jobs()).To(HaveLen(1))
			Expect(cluster.Status.MigratedImage).To(BeEmpty())

			finishJob(migrationJob(), batchv1.JobFailed)
			Expect(ensure()).To(BeTrue())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonSkipped))
		})

		It("should still refuse to downgrade", func() {
			start(nodeStatefulSet("gchq/stroom:v7.13.3"))

			Expect(ensure()).To(BeFalse())
			Expect(condition().Reason).To(Equal(stroomv1.MigrationReasonDowngradeBlocked))
			Expect(cluster.Status.MigratedImage).To(Equal("gchq/stroom:v7.13.3"))
		})
	})
})
