package v1

import (
	v1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
)

// StroomClusterSpec defines the desired state of StroomCluster
// +kubebuilder:validation:XValidation:rule="self.identityProviderType != 'EXTERNAL_IDP' || has(self.openId)",message="openId is required when identityProviderType is EXTERNAL_IDP"
// +kubebuilder:validation:XValidation:rule="has(self.nodeNamePrefix) == has(oldSelf.nodeNamePrefix) && (!has(self.nodeNamePrefix) || self.nodeNamePrefix == oldSelf.nodeNamePrefix)",message="nodeNamePrefix can't be added, changed or removed once the StroomCluster exists, as it determines the Stroom node names"
// +kubebuilder:validation:XValidation:rule="!((has(self.preventNodeRemoval) && self.preventNodeRemoval) || (has(oldSelf.preventNodeRemoval) && oldSelf.preventNodeRemoval)) || oldSelf.nodeSets.all(o, self.nodeSets.exists(n, n.name == o.name && n.count >= o.count))",message="preventNodeRemoval is set: a NodeSet's count can't go down, and a NodeSet can't be removed or renamed"
type StroomClusterSpec struct {
	// +kubebuilder:validation:Required
	Image           Image             `json:"image"`
	ImagePullPolicy corev1.PullPolicy `json:"imagePullPolicy,omitempty"`
	// DatabaseServerRef contains either the details of a DatabaseServer resource, or the TCP connection details of
	// an external MySQL database
	// +kubebuilder:validation:Required
	DatabaseServerRef DatabaseServerRef `json:"databaseServerRef"`
	// Name of the main Stroom database, usually `stroom`
	// +kubebuilder:default:="stroom"
	// +kubebuilder:validation:Pattern=`^[A-Za-z0-9_]{1,64}$`
	AppDatabaseName string `json:"appDatabaseName"`
	// Name of the statistics database, usually `stats`
	// +kubebuilder:default:="stats"
	// +kubebuilder:validation:Pattern=`^[A-Za-z0-9_]{1,64}$`
	StatsDatabaseName string `json:"statsDatabaseName"`
	// Override the Stroom configuration provided to each node, by providing the name of an existing `ConfigMap`
	// in the same namespace as the `StroomCluster`
	ConfigMapRef ConfigMapRef `json:"configMapRef,omitempty"`
	// Configures OpenID to enable operator components to query the Stroom API - Only needed with EXTERNAL_IDP
	// +kubebuilder:validation:Optional
	OpenId *OpenIdConfiguration `json:"openId,omitempty"`
	// INTERNAL_IDP means the operator creates and manages an API key; EXTERNAL_IDP requires openId
	// +kubebuilder:validation:Enum=INTERNAL_IDP;EXTERNAL_IDP
	// +kubebuilder:default:=INTERNAL_IDP
	IdentityProviderType IdentityProviderType `json:"identityProviderType,omitempty"`
	// HTTPS settings. Omit to use plain-text (HTTP)
	// +kubebuilder:validation:Optional
	Https HttpsSettings `json:"https,omitempty"`
	// +kubebuilder:validation:Required
	Ingress IngressSettings `json:"ingress"`
	// NodeNamePrefix replaces the default `stroom-<cluster name>-node` prefix of the NodeSets' StatefulSet, Service and
	// Pod names, and so of the Stroom node names: with prefix `stroom-prod`, the first node of NodeSet `proc` is
	// `stroom-prod-proc-0`. It can't be changed once the StroomCluster exists, as Stroom keys a node's index volumes,
	// jobs and other state by its name.
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:MaxLength=40
	// +kubebuilder:validation:Pattern=`^[a-z]([-a-z0-9]*[a-z0-9])?$`
	NodeNamePrefix string `json:"nodeNamePrefix,omitempty"`
	// PreventNodeRemoval refuses any change that would remove a Stroom node: a NodeSet's count going down, or a NodeSet
	// being removed or renamed. Stroom nodes own their index shards, so a node can't be removed without first moving or
	// deleting its data. To remove a node deliberately, set this to false in a separate update first.
	// +kubebuilder:validation:Optional
	PreventNodeRemoval bool `json:"preventNodeRemoval,omitempty"`
	// Stopped scales every NodeSet to zero Pods, each node draining its tasks first, without changing the NodeSets'
	// counts. Used to stop the whole cluster, for example for a Stroom version upgrade. PVCs are kept whatever the
	// volumeClaimDeletePolicy.
	// +kubebuilder:validation:Optional
	Stopped bool `json:"stopped,omitempty"`
	// Pod management policy to use when deploying or scaling the StroomCluster
	PodManagementPolicy v1.PodManagementPolicyType `json:"podManagementPolicy,omitempty"`
	// Amount of time granted to nodes to drain their active tasks before being terminated
	// +kubebuilder:default:=60
	NodeTerminationPeriodSecs int64 `json:"nodeTerminationPeriodSecs"`
	// Delete Stroom node `PersistentVolumeClaim`s in accordance with this policy
	VolumeClaimDeletePolicy VolumeClaimDeletePolicy `json:"volumeClaimDeletePolicy,omitempty"`

	// Each NodeSet is a functional grouping of Stroom nodes with a particular role, within the cluster.
	// It is recommended two NodeSets should be provided: one for storing and processing data and a separate one for
	// serving the Stroom front-end.
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=20
	NodeSets []NodeSet `json:"nodeSets"`

	// Additional Java Virtual Machine (JVM) options to use. Example of a valid entry: `-Xms1g`
	ExtraJvmOpts []string `json:"extraJvmOpts,omitempty"`
	// Additional environment variables provided to each NodeSet pod
	ExtraEnv []corev1.EnvVar `json:"extraEnv,omitempty"`
	// Additional volumes to be mounted in each NodeSet pod
	ExtraVolumes      []corev1.Volume      `json:"extraVolumes,omitempty"`
	ExtraVolumeMounts []corev1.VolumeMount `json:"extraVolumeMounts,omitempty"`

	// Configures the mechanism that posts internal audit and logging to Stroom
	LogSender *LogSenderSettings `json:"logSender,omitempty"`
}

type ConfigMapRef struct {
	// Name of the `ConfigMap`
	Name string `json:"name,omitempty"`
	// ConfigMap key containing the Stroom configuration data
	ItemName string `json:"itemName,omitempty"`
}

func (in *ConfigMapRef) IsZero() bool {
	if in == nil {
		return true
	}

	return in.Name == "" && in.ItemName == ""
}

type LogSenderSettings struct {
	// If `true`, Stroom internal audit and application logs are sent to the Stroom `Ingress` for ingestion
	// +kubebuilder:default:=false
	Enabled bool `json:"enabled"`
	// +kubebuilder:validation:Required
	Image           Image             `json:"image"`
	ImagePullPolicy corev1.PullPolicy `json:"imagePullPolicy,omitempty"`
	// Override the container security context
	SecurityContext corev1.SecurityContext `json:"securityContext,omitempty"`
	// Configure an alternate destination for events to be shipped to. If omitted, events are posted to the local cluster.
	DestinationUrl string `json:"destinationUrl,omitempty"`
	// Name of the `Environment` to set in feed metadata. If omitted, the cluster name is used (converted to UPPERCASE).
	EnvironmentName string `json:"environmentName,omitempty"`
	// Name of the `System` to set in feed metadata
	SystemName string                      `json:"systemName,omitempty"`
	Resources  corev1.ResourceRequirements `json:"resources,omitempty"`
	Tls        TlsSettings                 `json:"tls,omitempty"`
}

func (in *LogSenderSettings) IsZero() bool {
	if in == nil {
		return true
	}

	return !in.Enabled
}

type TlsSettings struct {
	// Name of the TLS Secret containing a CA certificate (ca.crt) and client certificate/key pair (tls.crt and tls.key)
	SecretName string `json:"secretName"`
}

func (in *TlsSettings) IsZero() bool {
	if in == nil {
		return true
	}

	return in.SecretName == ""
}

// GetIdentityProviderType returns the identity provider type, defaulting to INTERNAL_IDP if unset, e.g. when the
// operator is running against an older CRD that didn't apply the default
func (in *StroomClusterSpec) GetIdentityProviderType() IdentityProviderType {
	if in.IdentityProviderType == "" {
		return InternalIdp
	}
	return in.IdentityProviderType
}
