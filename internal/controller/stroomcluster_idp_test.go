package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("StroomCluster API key with each identity provider type", func() {
	ctx := context.Background()

	for _, idpType := range []stroomv1.IdentityProviderType{stroomv1.InternalIdp, stroomv1.ExternalIdp} {
		It("should create the API key Secret and mount the key on the nodes with "+string(idpType), func() {
			namespace := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "api-key-" + map[stroomv1.IdentityProviderType]string{
				stroomv1.InternalIdp: "internal", stroomv1.ExternalIdp: "external"}[idpType]}}
			Expect(client.IgnoreAlreadyExists(apiClient.Create(ctx, namespace))).To(Succeed())

			stroomCluster := &stroomv1.StroomCluster{
				ObjectMeta: metav1.ObjectMeta{Name: "idp", Namespace: namespace.Name, UID: "0c5c4f1e-3b7a-4f7e-9a39-2b2c3d4e5f61"},
				Spec: stroomv1.StroomClusterSpec{
					Image:                stroomv1.Image{Repository: "gchq/stroom", Tag: "v7.14.0"},
					IdentityProviderType: idpType,
					NodeSets:             []stroomv1.NodeSet{{Name: "proc", Count: 1}},
				},
			}
			reconciler := &StroomClusterReconciler{Client: apiClient, Scheme: scheme.Scheme}
			dbInfo := goldenDatabaseConnectionInfo("idp")

			// The first check creates the empty Secret for the API key Job to fill in, and holds the nodes until it has
			ready, result, err := reconciler.ensureApiKey(ctx, stroomCluster, dbInfo)
			Expect(err).ToNot(HaveOccurred())
			Expect(ready).To(BeFalse())
			Expect(result.RequeueAfter).ToNot(BeZero())
			secret := &corev1.Secret{}
			Expect(apiClient.Get(ctx, types.NamespacedName{Namespace: namespace.Name, Name: stroomCluster.GetApiKeySecretName()}, secret)).To(Succeed())

			podSpec := reconciler.createStatefulSet(stroomCluster, &stroomCluster.Spec.NodeSets[0], dbInfo).Spec.Template.Spec
			Expect(podSpec.Volumes).To(ContainElement(HaveField("Name", StroomApiKeyVolumeName)))
			Expect(podSpec.Containers[0].VolumeMounts).To(ContainElement(corev1.VolumeMount{
				Name: StroomApiKeyVolumeName, MountPath: StroomApiKeyMountPath, ReadOnly: true}))
		})
	}
})
