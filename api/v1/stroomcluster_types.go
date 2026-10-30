/*
Copyright 2021.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	StroomClusterLabel = "stroom/cluster"
	NodeSetLabel       = "stroom/nodeSet"
	// MaxNodeSetNameLength is the longest a NodeSet's StatefulSet name, from GetNodeSetName, can be. Its Pods'
	// controller-revision-hash label is the StatefulSet name, a hyphen and a hash of up to 10 characters, and must fit
	// in a label value's 63 characters; the Pod names and the NodeSet's `-http` Service name are then short enough too.
	// The StroomCluster's CEL rule checks it, as GetNodeSetName builds the name.
	MaxNodeSetNameLength = 52
)

// StroomClusterStatus defines the observed state of StroomCluster
type StroomClusterStatus struct {
	Nodes []string `json:"nodes,omitempty"`
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status

// StroomCluster is a cluster of Stroom nodes, in one or more NodeSets
// +kubebuilder:validation:XValidation:rule="!has(self.spec) || self.spec.nodeSets.all(n, (has(self.spec.nodeNamePrefix) ? size(self.spec.nodeNamePrefix) + 1 : size(self.metadata.name) + 13) + size(n.name) <= 52)",message="a NodeSet's StatefulSet name, <nodeNamePrefix>-<NodeSet name> or stroom-<cluster name>-node-<NodeSet name>, can be at most 52 characters: shorten the NodeSet, prefix or cluster name"
type StroomCluster struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   StroomClusterSpec   `json:"spec,omitempty"`
	Status StroomClusterStatus `json:"status,omitempty"`
}

func (in *StroomCluster) GetBaseName() string {
	return fmt.Sprintf("stroom-%v", in.Name)
}

func (in *StroomCluster) GetStaticContentConfigMapName() string {
	return fmt.Sprintf("%v-static-content", in.GetBaseName())
}

func (in *StroomCluster) GetApiKeySecretName() string {
	return fmt.Sprintf("%v-api-key", in.GetBaseName())
}

func (in *StroomCluster) GetApiKeyWriterRoleName() string {
	return fmt.Sprintf("%v-api-key-writer", in.GetBaseName())
}

// GetNodeSetName returns the name of a NodeSet's StatefulSet, which prefixes its Pod and so Stroom node names
func (in *StroomCluster) GetNodeSetName(nodeSet *NodeSet) string {
	if in.Spec.NodeNamePrefix != "" {
		return fmt.Sprintf("%v-%v", in.Spec.NodeNamePrefix, nodeSet.Name)
	}
	return fmt.Sprintf("%v-node-%v", in.GetBaseName(), nodeSet.Name)
}

// GetNodeSetReplicas returns how many Pods a NodeSet should run: none while the cluster is stopped
func (in *StroomCluster) GetNodeSetReplicas(nodeSet *NodeSet) int32 {
	if in.Spec.Stopped {
		return 0
	}
	return nodeSet.Count
}

func (in *StroomCluster) GetLogSenderConfigMapName() string {
	return fmt.Sprintf("%v-log-sender", in.GetBaseName())
}

func (in *StroomCluster) GetCliJobName(name string) string {
	return fmt.Sprintf("%v-cli-%v", in.GetBaseName(), name)
}

func (in *StroomCluster) GetLabels() map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":      "stroom",
		"app.kubernetes.io/component": "stroom-cluster",
		StroomClusterLabel:            in.Name,
	}
}

func (in *StroomCluster) GetNodeSetSelectorLabels(nodeSet *NodeSet) map[string]string {
	return map[string]string{
		StroomClusterLabel: in.Name,
		NodeSetLabel:       nodeSet.Name,
	}
}

func (in *StroomCluster) GetNodeSetHeadlessServiceName(nodeSet *NodeSet) string {
	return in.GetNodeSetName(nodeSet)
}

func (in *StroomCluster) GetNodeSetServiceName(nodeSet *NodeSet) string {
	return fmt.Sprintf("%v-http", in.GetNodeSetName(nodeSet))
}

func (in *StroomCluster) GetDatafeedUrl() string {
	return fmt.Sprintf("https://%v/stroom/datafeeddirect", in.Spec.Ingress.HostName)
}

func (in *StroomCluster) IsBeingDeleted() bool {
	return !in.ObjectMeta.DeletionTimestamp.IsZero()
}

//+kubebuilder:object:root=true

// StroomClusterList contains a list of StroomCluster
type StroomClusterList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []StroomCluster `json:"items"`
}

func init() {
	SchemeBuilder.Register(&StroomCluster{}, &StroomClusterList{})
}
