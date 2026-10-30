package controller

import (
	"regexp"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/kubernetes/scheme"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("StroomCluster node sets", func() {
	newCluster := func() *stroomv1.StroomCluster {
		return &stroomv1.StroomCluster{
			ObjectMeta: metav1.ObjectMeta{Name: "dev", Namespace: "stroom"},
			Spec: stroomv1.StroomClusterSpec{
				NodeNamePrefix: "stroom-dev",
				NodeSets:       []stroomv1.NodeSet{{Name: "proc", Count: 2}, {Name: "ui", Count: 1}},
			},
		}
	}
	reconciler := &StroomClusterReconciler{Scheme: scheme.Scheme}

	Context("clusterNodeNamePattern()", func() {
		It("should match the nodes of a cluster with a node name prefix, and no others", func() {
			pattern := regexp.MustCompile(clusterNodeNamePattern(newCluster()))
			for _, node := range []string{"stroom-dev-proc-0", "stroom-dev-proc-11", "stroom-dev-ui-0"} {
				Expect(pattern.MatchString(node)).To(BeTrue(), node)
			}
			for _, node := range []string{"stroom-dev-node-proc-0", "stroom-dev2-proc-0", "stroom-dev-processing-0"} {
				Expect(pattern.MatchString(node)).To(BeFalse(), node)
			}
		})
	})

	Context("createStatefulSet()", func() {
		dbInfo := goldenDatabaseConnectionInfo("dev")

		It("should name the StatefulSet from the node name prefix", func() {
			cluster := newCluster()
			statefulSet := reconciler.createStatefulSet(cluster, &cluster.Spec.NodeSets[0], dbInfo)
			Expect(statefulSet.Name).To(Equal("stroom-dev-proc"))
			Expect(statefulSet.Spec.ServiceName).To(Equal("stroom-dev-proc"))
		})
		It("should run the NodeSet's count of Pods, or none while the cluster is stopped", func() {
			cluster := newCluster()
			Expect(*reconciler.createStatefulSet(cluster, &cluster.Spec.NodeSets[0], dbInfo).Spec.Replicas).To(Equal(int32(2)))
			cluster.Spec.Stopped = true
			Expect(*reconciler.createStatefulSet(cluster, &cluster.Spec.NodeSets[0], dbInfo).Spec.Replicas).To(Equal(int32(0)))
		})
		It("should select the NodeSet's own Pods in topology spread constraints without a label selector", func() {
			cluster := newCluster()
			nodeSet := &cluster.Spec.NodeSets[0]
			ownSelector := &metav1.LabelSelector{MatchLabels: map[string]string{"app": "other"}}
			nodeSet.TopologySpreadConstraints = []corev1.TopologySpreadConstraint{
				{MaxSkew: 1, TopologyKey: "topology.kubernetes.io/zone", WhenUnsatisfiable: corev1.DoNotSchedule},
				{MaxSkew: 1, TopologyKey: "kubernetes.io/hostname", WhenUnsatisfiable: corev1.ScheduleAnyway, LabelSelector: ownSelector},
			}
			constraints := reconciler.createStatefulSet(cluster, nodeSet, dbInfo).Spec.Template.Spec.TopologySpreadConstraints
			Expect(constraints).To(HaveLen(2))
			Expect(constraints[0].LabelSelector.MatchLabels).To(Equal(cluster.GetNodeSetSelectorLabels(nodeSet)))
			Expect(constraints[1].LabelSelector).To(Equal(ownSelector))
			Expect(nodeSet.TopologySpreadConstraints[0].LabelSelector).To(BeNil(), "the NodeSet's own constraints are unchanged")
		})
	})

	Context("createPodDisruptionBudget()", func() {
		It("should create none unless the NodeSet asks for one", func() {
			cluster := newCluster()
			Expect(reconciler.createPodDisruptionBudget(cluster, &cluster.Spec.NodeSets[0])).To(BeNil())
		})
		It("should allow one Pod down by default, selecting the NodeSet's Pods", func() {
			cluster := newCluster()
			nodeSet := &cluster.Spec.NodeSets[0]
			nodeSet.PodDisruptionBudget = &stroomv1.PodDisruptionBudgetSettings{}
			pdb := reconciler.createPodDisruptionBudget(cluster, nodeSet)
			Expect(pdb.Name).To(Equal("stroom-dev-proc"))
			Expect(*pdb.Spec.MaxUnavailable).To(Equal(intstr.FromInt32(1)))
			Expect(pdb.Spec.Selector.MatchLabels).To(Equal(cluster.GetNodeSetSelectorLabels(nodeSet)))
		})
		It("should use the NodeSet's maxUnavailable", func() {
			cluster := newCluster()
			nodeSet := &cluster.Spec.NodeSets[0]
			maxUnavailable := intstr.FromString("50%")
			nodeSet.PodDisruptionBudget = &stroomv1.PodDisruptionBudgetSettings{MaxUnavailable: &maxUnavailable}
			Expect(*reconciler.createPodDisruptionBudget(cluster, nodeSet).Spec.MaxUnavailable).To(Equal(maxUnavailable))
		})
	})
})
