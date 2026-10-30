package controller

import (
	"context"
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("StroomCluster reconciliation", func() {
	ctx := context.Background()

	Context("while the API key Job hasn't created a key", func() {
		// reconcile reconciles a new StroomCluster with an external database a few times, as its API key Job never runs
		// here, and returns the NodeSet's StatefulSet, if any
		reconcile := func(idpType stroomv1.IdentityProviderType) (*StroomClusterReconciler, *stroomv1.StroomCluster, *appsv1.StatefulSet) {
			testScheme := runtime.NewScheme()
			Expect(clientgoscheme.AddToScheme(testScheme)).To(Succeed())
			Expect(stroomv1.AddToScheme(testScheme)).To(Succeed())
			cluster := &stroomv1.StroomCluster{
				ObjectMeta: metav1.ObjectMeta{Name: "dev", Namespace: "stroom"},
				Spec: stroomv1.StroomClusterSpec{
					Image: stroomv1.Image{Repository: "gchq/stroom", Tag: "v7.14.0"},
					DatabaseServerRef: stroomv1.DatabaseServerRef{
						ServerAddress: stroomv1.ServerAddress{Host: "mysql.example.com", Port: 3306, SecretName: "db"},
						UserName:      "stroomuser",
					},
					IdentityProviderType: idpType,
					Ingress:              stroomv1.IngressSettings{HostName: "stroom.example.com"},
					NodeSets:             []stroomv1.NodeSet{{Name: "proc", Count: 1}},
				},
			}
			if idpType == stroomv1.ExternalIdp {
				cluster.Spec.OpenId = &stroomv1.OpenIdConfiguration{}
			}
			fakeClient := fake.NewClientBuilder().WithScheme(testScheme).WithObjects(cluster).Build()
			reconciler := &StroomClusterReconciler{Client: fakeClient, Scheme: testScheme, Recorder: events.NewFakeRecorder(10)}

			var result ctrl.Result
			for range 5 {
				var err error
				result, err = reconciler.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(cluster)})
				Expect(err).ToNot(HaveOccurred())
			}
			// The API key Job is checked again, whether or not the nodes are held
			Expect(result.RequeueAfter).ToNot(BeZero())

			// The API key Job runs, and is retried until it succeeds
			job := &batchv1.Job{}
			Expect(fakeClient.Get(ctx, types.NamespacedName{Namespace: "stroom", Name: cluster.GetCliJobName("api-key")}, job)).To(Succeed())

			statefulSet := &appsv1.StatefulSet{}
			err := fakeClient.Get(ctx, types.NamespacedName{Namespace: "stroom", Name: cluster.GetNodeSetName(&cluster.Spec.NodeSets[0])}, statefulSet)
			if errors.IsNotFound(err) {
				return reconciler, cluster, nil
			}
			Expect(err).ToNot(HaveOccurred())
			return reconciler, cluster, statefulSet
		}

		It("should hold the nodes with INTERNAL_IDP, as the node scripts need the key", func() {
			_, _, statefulSet := reconcile(stroomv1.InternalIdp)
			Expect(statefulSet).To(BeNil())
		})

		It("should reconcile the nodes with EXTERNAL_IDP, whose node scripts can use a token from the IdP", func() {
			_, _, statefulSet := reconcile(stroomv1.ExternalIdp)
			Expect(statefulSet).ToNot(BeNil())
			// The nodes start without the key, and it appears in the volume once it's written
			var apiKeyVolume *corev1.Volume
			for i := range statefulSet.Spec.Template.Spec.Volumes {
				if statefulSet.Spec.Template.Spec.Volumes[i].Name == StroomApiKeyVolumeName {
					apiKeyVolume = &statefulSet.Spec.Template.Spec.Volumes[i]
				}
			}
			Expect(apiKeyVolume).ToNot(BeNil())
			Expect(apiKeyVolume.Secret.Optional).To(HaveValue(BeTrue()))
		})
	})

	// These run against the test API server. The StroomClusters aren't created: their objects only need a UID for
	// their owner references.
	Context("with the test API server", func() {
		var (
			namespace  string
			cluster    *stroomv1.StroomCluster
			reconciler *StroomClusterReconciler
			recorder   *events.FakeRecorder
			dbInfo     *DatabaseConnectionInfo
		)

		newNodeSet := func(name string, count int32) stroomv1.NodeSet {
			nodeSet := stroomv1.NodeSet{Name: name, Count: count}
			nodeSet.LocalDataVolumeClaim.AccessModes = []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}
			nodeSet.LocalDataVolumeClaim.Resources.Requests = corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("1Gi")}
			return nodeSet
		}
		newCluster := func(name string, uid types.UID) *stroomv1.StroomCluster {
			return &stroomv1.StroomCluster{
				ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace, UID: uid},
				Spec: stroomv1.StroomClusterSpec{
					Image:    stroomv1.Image{Repository: "gchq/stroom", Tag: "v7.14.0"},
					NodeSets: []stroomv1.NodeSet{newNodeSet("proc", 3)},
				},
			}
		}

		var namespaceCount int
		BeforeEach(func() {
			namespaceCount++
			namespace = fmt.Sprintf("reconcile-%v", namespaceCount)
			Expect(client.IgnoreAlreadyExists(apiClient.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: namespace}}))).To(Succeed())
			cluster = newCluster("dev", "0b7e3a52-8d5c-4e1f-a3b9-6c2d1e0f9a71")
			recorder = events.NewFakeRecorder(10)
			reconciler = &StroomClusterReconciler{Client: apiClient, Scheme: clientgoscheme.Scheme, Recorder: recorder}
			dbInfo = goldenDatabaseConnectionInfo("dev")
		})

		Context("objects of another StroomCluster with the same names", func() {
			It("should refuse to change another StroomCluster's StatefulSet, with a Warning Event", func() {
				// The other cluster's nodeNamePrefix gives its StatefulSet the same name as this cluster's
				other := newCluster("other", "5d1c9e2a-7b3f-4a6e-8c0d-2e9f1b4a7c35")
				other.Spec.NodeNamePrefix = "stroom-dev-node"
				otherNodeSet := &other.Spec.NodeSets[0]
				Expect(reconciler.reconcileNodeStatefulSet(ctx, other, otherNodeSet, dbInfo)).To(Succeed())

				err := reconciler.reconcileNodeStatefulSet(ctx, cluster, &cluster.Spec.NodeSets[0], dbInfo)
				Expect(err).To(MatchError(ContainSubstring("isn't controlled by StroomCluster dev")))
				Expect(recorder.Events).To(Receive(ContainSubstring("NameConflict")))

				statefulSet := &appsv1.StatefulSet{}
				Expect(apiClient.Get(ctx, types.NamespacedName{Namespace: namespace, Name: other.GetNodeSetName(otherNodeSet)}, statefulSet)).To(Succeed())
				Expect(metav1.IsControlledBy(statefulSet, other)).To(BeTrue())
			})

			It("should refuse to change another StroomCluster's PodDisruptionBudget", func() {
				other := newCluster("other", "5d1c9e2a-7b3f-4a6e-8c0d-2e9f1b4a7c35")
				other.Spec.NodeNamePrefix = "stroom-dev-node"
				other.Spec.NodeSets[0].PodDisruptionBudget = &stroomv1.PodDisruptionBudgetSettings{}
				Expect(reconciler.reconcilePodDisruptionBudget(ctx, other, &other.Spec.NodeSets[0])).To(Succeed())

				cluster.Spec.NodeSets[0].PodDisruptionBudget = &stroomv1.PodDisruptionBudgetSettings{}
				err := reconciler.reconcilePodDisruptionBudget(ctx, cluster, &cluster.Spec.NodeSets[0])
				Expect(err).To(MatchError(ContainSubstring("isn't controlled by StroomCluster dev")))
				Expect(recorder.Events).To(Receive(ContainSubstring("NameConflict")))
			})

			It("should adopt an object with the StroomCluster's label and no controller, as earlier versions' Ingresses", func() {
				ingresses := reconciler.createIngresses(ctx, cluster)
				Expect(ingresses).ToNot(BeEmpty())
				for i := range ingresses {
					Expect(metav1.IsControlledBy(&ingresses[i], cluster)).To(BeTrue())
				}

				existing := ingresses[0].DeepCopy()
				existing.OwnerReferences = nil
				existing.ResourceVersion = "1"
				Expect(reconciler.checkControlled(cluster, existing, "Ingress")).To(Succeed())
				existing.Labels = nil
				Expect(reconciler.checkControlled(cluster, existing, "Ingress")).ToNot(Succeed())
			})

			It("should still update its own objects", func() {
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, &cluster.Spec.NodeSets[0], dbInfo)).To(Succeed())
				cluster.Spec.NodeSets[0].Count = 4
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, &cluster.Spec.NodeSets[0], dbInfo)).To(Succeed())
				Expect(recorder.Events).ToNot(Receive())
			})
		})

		Context("deleteRemovedPodDisruptionBudgets()", func() {
			pdbExists := func(name string) bool {
				err := apiClient.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, &policyv1.PodDisruptionBudget{})
				if errors.IsNotFound(err) {
					return false
				}
				Expect(err).ToNot(HaveOccurred())
				return true
			}

			It("should delete the PodDisruptionBudgets of removed NodeSets, and no others", func() {
				cluster.Spec.NodeSets = []stroomv1.NodeSet{
					{Name: "proc", Count: 1, PodDisruptionBudget: &stroomv1.PodDisruptionBudgetSettings{}},
					{Name: "ui", Count: 1, PodDisruptionBudget: &stroomv1.PodDisruptionBudgetSettings{}},
				}
				for i := range cluster.Spec.NodeSets {
					Expect(reconciler.reconcilePodDisruptionBudget(ctx, cluster, &cluster.Spec.NodeSets[i])).To(Succeed())
				}
				// A PodDisruptionBudget with the cluster's labels that the cluster doesn't control
				foreign := reconciler.createPodDisruptionBudget(cluster, &stroomv1.NodeSet{Name: "foreign", PodDisruptionBudget: &stroomv1.PodDisruptionBudgetSettings{}})
				foreign.OwnerReferences = nil
				Expect(apiClient.Create(ctx, foreign)).To(Succeed())

				procName := cluster.GetNodeSetName(&cluster.Spec.NodeSets[0])
				uiName := cluster.GetNodeSetName(&cluster.Spec.NodeSets[1])
				cluster.Spec.NodeSets = cluster.Spec.NodeSets[:1]
				Expect(reconciler.deleteRemovedPodDisruptionBudgets(ctx, cluster)).To(Succeed())

				Expect(pdbExists(procName)).To(BeTrue())
				Expect(pdbExists(uiName)).To(BeFalse())
				Expect(pdbExists(foreign.Name)).To(BeTrue())
			})
		})

		Context("deletePvcs()", func() {
			// createPvcs creates PVCs for the NodeSet's nodes, as its StatefulSet would
			createPvcs := func(nodeSet *stroomv1.NodeSet, count int) {
				for ordinal := range count {
					pvc := &corev1.PersistentVolumeClaim{
						ObjectMeta: metav1.ObjectMeta{
							Name:      fmt.Sprintf("%v-%v-%v", StroomNodePvcName, cluster.GetNodeSetName(nodeSet), ordinal),
							Namespace: namespace,
							Labels:    reconciler.createNodeSetPvcLabels(cluster, nodeSet),
						},
						Spec: corev1.PersistentVolumeClaimSpec{
							AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
							Resources: corev1.VolumeResourceRequirements{
								Requests: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("1Gi")},
							},
						},
					}
					Expect(apiClient.Create(ctx, pvc)).To(Succeed())
				}
			}
			// remainingPvcs returns the ordinals of the NodeSet's PVCs that aren't being deleted. PVCs aren't removed
			// straight away, as the API server adds a protection finalizer.
			remainingPvcs := func() []string {
				var pvcs corev1.PersistentVolumeClaimList
				Expect(apiClient.List(ctx, &pvcs, client.InNamespace(namespace))).To(Succeed())
				var names []string
				for _, pvc := range pvcs.Items {
					if pvc.DeletionTimestamp.IsZero() {
						names = append(names, pvc.Name)
					}
				}
				return names
			}
			pvcName := func(nodeSet *stroomv1.NodeSet, ordinal int) string {
				return fmt.Sprintf("%v-%v-%v", StroomNodePvcName, cluster.GetNodeSetName(nodeSet), ordinal)
			}

			It("should delete the PVCs of nodes removed while the cluster was stopped, once it starts", func() {
				cluster.Spec.VolumeClaimDeletePolicy = stroomv1.DeleteOnScaledownOnlyPolicy
				nodeSet := &cluster.Spec.NodeSets[0]
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())
				createPvcs(nodeSet, 3)

				// Stop the cluster, then lower the count while it's stopped: the PVCs are kept
				cluster.Spec.Stopped = true
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())
				nodeSet.Count = 1
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())
				Expect(remainingPvcs()).To(HaveLen(3))

				// Start it again: the StatefulSet had no Pods, but the removed nodes' PVCs are deleted
				cluster.Spec.Stopped = false
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())
				Expect(remainingPvcs()).To(ConsistOf(pvcName(nodeSet, 0)))
			})

			It("should keep the PVCs without a scale-down deletion policy", func() {
				nodeSet := &cluster.Spec.NodeSets[0]
				createPvcs(nodeSet, 3)
				nodeSet.Count = 1
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())
				Expect(remainingPvcs()).To(HaveLen(3))
			})

			It("should delete only the NodeSet's own PVCs", func() {
				cluster.Spec.VolumeClaimDeletePolicy = stroomv1.DeleteOnScaledownAndClusterDeletionPolicy
				cluster.Spec.NodeSets = []stroomv1.NodeSet{newNodeSet("proc", 2), newNodeSet("proc-1", 2)}
				createPvcs(&cluster.Spec.NodeSets[0], 2)
				createPvcs(&cluster.Spec.NodeSets[1], 2)
				nodeSet := &cluster.Spec.NodeSets[0]
				nodeSet.Count = 1
				Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())
				other := &cluster.Spec.NodeSets[1]
				Expect(remainingPvcs()).To(ConsistOf(pvcName(nodeSet, 0), pvcName(other, 0), pvcName(other, 1)))
			})
		})
	})
})
