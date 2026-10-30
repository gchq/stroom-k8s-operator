package v1

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/rand"
)

var _ = Describe("StroomCluster node names", func() {
	nodeSet := &NodeSet{Name: "proc"}

	It("should name NodeSets after the cluster by default", func() {
		cluster := &StroomCluster{ObjectMeta: metav1.ObjectMeta{Name: "prod"}}
		Expect(cluster.GetNodeSetName(nodeSet)).To(Equal("stroom-prod-node-proc"))
		Expect(cluster.GetNodeSetServiceName(nodeSet)).To(Equal("stroom-prod-node-proc-http"))
	})
	It("should name NodeSets after nodeNamePrefix, when set", func() {
		cluster := &StroomCluster{ObjectMeta: metav1.ObjectMeta{Name: "prod"}}
		cluster.Spec.NodeNamePrefix = "stroom-prod"
		Expect(cluster.GetNodeSetName(nodeSet)).To(Equal("stroom-prod-proc"))
		Expect(cluster.GetNodeSetHeadlessServiceName(nodeSet)).To(Equal("stroom-prod-proc"))
		Expect(cluster.GetNodeSetServiceName(nodeSet)).To(Equal("stroom-prod-proc-http"))
	})
	It("should run no Pods while the cluster is stopped", func() {
		cluster := &StroomCluster{}
		nodeSet := &NodeSet{Name: "proc", Count: 3}
		Expect(cluster.GetNodeSetReplicas(nodeSet)).To(Equal(int32(3)))
		cluster.Spec.Stopped = true
		Expect(cluster.GetNodeSetReplicas(nodeSet)).To(Equal(int32(0)))
	})
})

var _ = Describe("StroomCluster node validation", func() {
	ctx := context.Background()

	newCluster := func(nodeSets ...NodeSet) *StroomCluster {
		return &StroomCluster{
			ObjectMeta: metav1.ObjectMeta{Name: "stroom-" + rand.String(5), Namespace: "default"},
			Spec: StroomClusterSpec{
				Image:             Image{Repository: "gchq/stroom"},
				AppDatabaseName:   "stroom",
				StatsDatabaseName: "stats",
				NodeSets:          nodeSets,
			},
		}
	}
	nodeSet := func(name string, count int32) NodeSet {
		return NodeSet{
			Name:          name,
			Count:         count,
			MemoryOptions: JvmMemoryOptions{InitialPercentage: 50, MaxPercentage: 75},
		}
	}
	create := func(cluster *StroomCluster) *StroomCluster {
		Expect(k8sClient.Create(ctx, cluster)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, cluster)).To(Succeed()) })
		return cluster
	}
	expectRefused := func(cluster *StroomCluster, message string) {
		err := k8sClient.Update(ctx, cluster)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring(message))
	}

	Context("nodeNamePrefix", func() {
		It("should refuse a prefix that isn't a DNS label", func() {
			cluster := newCluster(nodeSet("proc", 1))
			cluster.Spec.NodeNamePrefix = "Stroom_Prod"
			Expect(k8sClient.Create(ctx, cluster)).ToNot(Succeed())
		})
		It("should refuse a change to the prefix", func() {
			cluster := newCluster(nodeSet("proc", 1))
			cluster.Spec.NodeNamePrefix = "stroom-prod"
			create(cluster)
			cluster.Spec.NodeNamePrefix = "stroom-live"
			expectRefused(cluster, "nodeNamePrefix can't be added, changed or removed")
		})
		It("should refuse removing the prefix", func() {
			cluster := newCluster(nodeSet("proc", 1))
			cluster.Spec.NodeNamePrefix = "stroom-prod"
			create(cluster)
			cluster.Spec.NodeNamePrefix = ""
			expectRefused(cluster, "nodeNamePrefix can't be added, changed or removed")
		})
		It("should refuse adding a prefix to an existing cluster", func() {
			cluster := create(newCluster(nodeSet("proc", 1)))
			cluster.Spec.NodeNamePrefix = "stroom-prod"
			expectRefused(cluster, "nodeNamePrefix can't be added, changed or removed")
		})
		It("should allow other changes to a cluster with a prefix", func() {
			cluster := newCluster(nodeSet("proc", 1))
			cluster.Spec.NodeNamePrefix = "stroom-prod"
			create(cluster)
			cluster.Spec.NodeSets[0].Count = 2
			Expect(k8sClient.Update(ctx, cluster)).To(Succeed())
		})
	})

	Context("preventNodeRemoval", func() {
		guarded := func() *StroomCluster {
			cluster := newCluster(nodeSet("proc", 2), nodeSet("ui", 1))
			cluster.Spec.PreventNodeRemoval = true
			return create(cluster)
		}
		const refusal = "preventNodeRemoval is set"

		It("should refuse a lower count", func() {
			cluster := guarded()
			cluster.Spec.NodeSets[0].Count = 1
			expectRefused(cluster, refusal)
		})
		It("should refuse removing a NodeSet", func() {
			cluster := guarded()
			cluster.Spec.NodeSets = cluster.Spec.NodeSets[:1]
			expectRefused(cluster, refusal)
		})
		It("should refuse renaming a NodeSet", func() {
			cluster := guarded()
			cluster.Spec.NodeSets[1].Name = "frontend"
			expectRefused(cluster, refusal)
		})
		It("should allow a higher count and a new NodeSet", func() {
			cluster := guarded()
			cluster.Spec.NodeSets[0].Count = 3
			cluster.Spec.NodeSets = append(cluster.Spec.NodeSets, nodeSet("extra", 1))
			Expect(k8sClient.Update(ctx, cluster)).To(Succeed())
		})
		It("should allow stopping the cluster, which doesn't change the counts", func() {
			cluster := guarded()
			cluster.Spec.Stopped = true
			Expect(k8sClient.Update(ctx, cluster)).To(Succeed())
		})
		It("should allow a lower count once it's turned off", func() {
			cluster := guarded()
			cluster.Spec.PreventNodeRemoval = false
			Expect(k8sClient.Update(ctx, cluster)).To(Succeed())
			cluster.Spec.NodeSets[0].Count = 1
			Expect(k8sClient.Update(ctx, cluster)).To(Succeed())
		})
		It("should refuse turning it off and lowering a count in one update", func() {
			cluster := guarded()
			cluster.Spec.PreventNodeRemoval = false
			cluster.Spec.NodeSets[0].Count = 1
			expectRefused(cluster, refusal)
		})
		It("should allow a lower count without it", func() {
			cluster := create(newCluster(nodeSet("proc", 2)))
			cluster.Spec.NodeSets[0].Count = 1
			Expect(k8sClient.Update(ctx, cluster)).To(Succeed())
		})
	})
})
