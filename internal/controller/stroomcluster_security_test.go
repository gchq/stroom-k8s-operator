package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("StroomCluster Pod security", func() {

	// The API server's Pod Security admission checks each Pod created in a namespace that enforces a level, so Pods
	// made from the templates the operator renders show whether its Pods meet that level
	const namespace = "restricted-pods"
	ctx := context.Background()

	var stroomCluster *stroomv1.StroomCluster
	BeforeEach(func() {
		ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name:   namespace,
			Labels: map[string]string{"pod-security.kubernetes.io/enforce": "restricted"},
		}}
		Expect(client.IgnoreAlreadyExists(apiClient.Create(ctx, ns))).To(Succeed())
		objects := createFixture("testdata/fixtures/external-db.yaml", namespace)
		stroomCluster = objects[0].(*stroomv1.StroomCluster)
	})

	createPod := func(name string, spec corev1.PodSpec) error {
		pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}, Spec: spec}
		return apiClient.Create(ctx, pod, client.DryRunAll)
	}
	render := func(stroomCluster *stroomv1.StroomCluster) (nodePod corev1.PodSpec, apiKeyJobPod corev1.PodSpec) {
		reconciler := &StroomClusterReconciler{Client: apiClient, Scheme: scheme.Scheme}
		dbInfo := goldenStroomClusterDatabaseConnectionInfo(stroomCluster)
		nodeSet := &stroomCluster.Spec.NodeSets[0]
		statefulSet := reconciler.createStatefulSet(stroomCluster, nodeSet, dbInfo)
		nodePod = statefulSet.Spec.Template.Spec
		// Add the claim template volumes, as the StatefulSet controller does
		for _, claimTemplate := range statefulSet.Spec.VolumeClaimTemplates {
			nodePod.Volumes = append(nodePod.Volumes, corev1.Volume{
				Name: claimTemplate.Name,
				VolumeSource: corev1.VolumeSource{PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
					ClaimName: claimTemplate.Name + "-" + statefulSet.Name + "-0",
				}},
			})
		}
		return nodePod, reconciler.createApiKeyJob(stroomCluster, dbInfo).Spec.Template.Spec
	}

	It("should create node and API key Job Pods that meet the restricted level, init containers included", func() {
		nodePod, apiKeyJobPod := render(stroomCluster)
		Expect(nodePod.InitContainers).ToNot(BeEmpty())
		Expect(apiKeyJobPod.InitContainers).ToNot(BeEmpty())

		Expect(createPod("node", nodePod)).To(Succeed())
		Expect(createPod("api-key-job", apiKeyJobPod)).To(Succeed())
	})

	It("should be refused without the NodeSet's security settings, so the check above means something", func() {
		stroomCluster.Spec.NodeSets[0].PodSecurityContext = corev1.PodSecurityContext{}
		stroomCluster.Spec.NodeSets[0].SecurityContext = corev1.SecurityContext{}
		nodePod, _ := render(stroomCluster)
		err := createPod("node-default", nodePod)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("restricted"))
	})
})
