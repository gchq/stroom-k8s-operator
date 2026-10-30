package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("StroomCluster node storage", func() {

	Context("nodeDirectoryVolumes()", func() {
		mountFor := func(mounts []corev1.VolumeMount, path string) corev1.VolumeMount {
			for _, mount := range mounts {
				if mount.MountPath == path {
					return mount
				}
			}
			Fail("no mount at " + path)
			return corev1.VolumeMount{}
		}

		It("should put every directory on the local data volume by default", func() {
			volumes, mounts := nodeDirectoryVolumes(&stroomv1.NodeSet{})
			Expect(volumes).To(BeEmpty())
			Expect(mounts).To(HaveLen(len(nodeDirectories)))
			for _, mount := range mounts {
				Expect(mount.Name).To(Equal(StroomNodePvcName))
				Expect(mount.SubPath).ToNot(BeEmpty())
			}
			Expect(mountFor(mounts, "/stroom/reference_data").SubPath).To(Equal("reference-data"))
		})
		It("should put directories with an emptyDir on a volume of their own", func() {
			sizeLimit := resource.MustParse("200Gi")
			nodeSet := &stroomv1.NodeSet{Directories: &stroomv1.NodeDirectories{
				ReferenceData: &stroomv1.DirectoryVolume{EmptyDir: &corev1.EmptyDirVolumeSource{SizeLimit: &sizeLimit}},
				Tmp:           &stroomv1.DirectoryVolume{EmptyDir: &corev1.EmptyDirVolumeSource{}},
			}}
			volumes, mounts := nodeDirectoryVolumes(nodeSet)

			Expect(volumes).To(HaveLen(2))
			Expect(volumes[0].Name).To(Equal("dir-tmp"))
			Expect(volumes[1].Name).To(Equal("dir-reference-data"))
			Expect(*volumes[1].EmptyDir.SizeLimit).To(Equal(sizeLimit))

			Expect(mountFor(mounts, "/stroom/reference_data")).To(Equal(corev1.VolumeMount{Name: "dir-reference-data", MountPath: "/stroom/reference_data"}))
			Expect(mountFor(mounts, "/stroom/tmp")).To(Equal(corev1.VolumeMount{Name: "dir-tmp", MountPath: "/stroom/tmp"}))
			Expect(mountFor(mounts, "/stroom/lmdb").Name).To(Equal(StroomNodePvcName), "directories not set stay on the data volume")
			Expect(mounts).To(HaveLen(len(nodeDirectories)))
		})
	})

	Context("volumeClaimTemplatesMatch()", func() {
		template := func(size string) corev1.PersistentVolumeClaim {
			return corev1.PersistentVolumeClaim{
				ObjectMeta: metav1.ObjectMeta{Name: StroomNodePvcName},
				Spec: corev1.PersistentVolumeClaimSpec{
					AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
					Resources:   corev1.VolumeResourceRequirements{Requests: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse(size)}},
				},
			}
		}
		It("should ignore fields the API server defaults", func() {
			existing := template("10Gi")
			storageClass := "gp3"
			volumeMode := corev1.PersistentVolumeFilesystem
			existing.Spec.StorageClassName = &storageClass
			existing.Spec.VolumeMode = &volumeMode
			Expect(volumeClaimTemplatesMatch([]corev1.PersistentVolumeClaim{existing}, []corev1.PersistentVolumeClaim{template("10Gi")})).To(BeTrue())
		})
		It("should see a different storage request", func() {
			Expect(volumeClaimTemplatesMatch([]corev1.PersistentVolumeClaim{template("10Gi")}, []corev1.PersistentVolumeClaim{template("20Gi")})).To(BeFalse())
		})
	})

	Context("reconcileNodeStatefulSet()", func() {
		ctx := context.Background()

		It("should keep the volume claim templates of an existing StatefulSet, and still apply other changes", func() {
			namespace := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "storage-vct"}}
			Expect(client.IgnoreAlreadyExists(apiClient.Create(ctx, namespace))).To(Succeed())

			cluster := &stroomv1.StroomCluster{
				// The StroomCluster isn't created: the StatefulSet only needs a UID for its owner reference
				ObjectMeta: metav1.ObjectMeta{Name: "vct", Namespace: namespace.Name, UID: "6f1d2c1e-4f7e-4a39-9c1a-1b2c3d4e5f60"},
				Spec: stroomv1.StroomClusterSpec{
					Image:    stroomv1.Image{Repository: "gchq/stroom", Tag: "v7.14.0"},
					NodeSets: []stroomv1.NodeSet{{Name: "proc", Count: 1}},
				},
			}
			nodeSet := &cluster.Spec.NodeSets[0]
			nodeSet.LocalDataVolumeClaim.AccessModes = []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}
			nodeSet.LocalDataVolumeClaim.Resources.Requests = corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("10Gi")}
			reconciler := &StroomClusterReconciler{Client: apiClient, Scheme: scheme.Scheme}
			dbInfo := goldenDatabaseConnectionInfo("vct")

			Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())

			nodeSet.LocalDataVolumeClaim.Resources.Requests[corev1.ResourceStorage] = resource.MustParse("20Gi")
			nodeSet.Count = 2
			Expect(reconciler.reconcileNodeStatefulSet(ctx, cluster, nodeSet, dbInfo)).To(Succeed())

			statefulSet := &appsv1.StatefulSet{}
			Expect(apiClient.Get(ctx, types.NamespacedName{Namespace: namespace.Name, Name: cluster.GetNodeSetName(nodeSet)}, statefulSet)).To(Succeed())
			Expect(*statefulSet.Spec.Replicas).To(Equal(int32(2)))
			Expect(statefulSet.Spec.VolumeClaimTemplates[0].Spec.Resources.Requests[corev1.ResourceStorage]).To(Equal(resource.MustParse("10Gi")))
		})
	})
})
