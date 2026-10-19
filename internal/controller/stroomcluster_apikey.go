package controller

import (
	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
)

const (
	// Secret data item containing the API key. Must match the key written by the API key script.
	ApiKeySecretDataKey    = "apiKey"
	ApiKeyJobScriptName    = "create-stroom-api-key.sh"
	ApiKeyJobContainerName = "create-api-key"
)

// createApiKeyJob creates a Job that uses the Stroom CLI to create an API key for the operator, then writes it
// to the cluster's API key Secret. Only used when the cluster uses Stroom's internal identity provider.
func (r *StroomClusterReconciler) createApiKeyJob(stroomCluster *stroomv1.StroomCluster, dbInfo *DatabaseConnectionInfo) *batchv1.Job {
	// Run with the same security and scheduling settings as the first NodeSet. The CRD requires at least one.
	nodeSet := &stroomCluster.Spec.NodeSets[0]

	env := r.getStroomCommonEnv(stroomCluster, dbInfo)
	env = append(env, r.getIdentityProviderEnv(stroomCluster))
	env = append(env, stroomCluster.Spec.ExtraEnv...)
	// Job-specific variables come last, so they take precedence over any in ExtraEnv
	env = append(env, []corev1.EnvVar{{
		Name: "POD_NAMESPACE",
		ValueFrom: &corev1.EnvVarSource{
			FieldRef: &corev1.ObjectFieldSelector{
				FieldPath: "metadata.namespace",
			},
		},
	}, {
		Name:  "STROOM_API_KEY_SECRET_NAME",
		Value: stroomCluster.GetApiKeySecretName(),
	}, {
		// The CLI needs far less memory than a Stroom node
		Name:  "JAVA_OPTS",
		Value: "-Xms128m -Xmx1g",
	}}...)

	volumes := []corev1.Volume{
		*r.createStaticContentVolume(stroomCluster),
		{
			Name:         "api-key-output",
			VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
		},
		{
			Name:         "stroom-tmp",
			VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
		},
		{
			Name:         "stroom-logs",
			VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
		},
	}
	if !stroomCluster.Spec.ConfigMapRef.IsZero() {
		volumes = append(volumes, *r.createConfigOverrideVolume(stroomCluster))
	}

	volumeMounts := []corev1.VolumeMount{{
		Name:      StaticContentVolumeName,
		SubPath:   ApiKeyJobScriptName,
		MountPath: "/stroom/scripts/" + ApiKeyJobScriptName,
		ReadOnly:  true,
	}, {
		Name:      "api-key-output",
		MountPath: "/tmp/api-key",
	}, {
		Name:      "stroom-tmp",
		MountPath: "/stroom/tmp",
	}, {
		Name:      "stroom-logs",
		MountPath: "/stroom/logs",
	}}
	r.appendConfigVolumeMounts(stroomCluster, &volumeMounts)

	var backoffLimit int32 = 3
	var activeDeadlineSeconds int64 = 1200
	var ttlSecondsAfterFinished int32 = 3600

	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      stroomCluster.GetCliJobName("api-key"),
			Namespace: stroomCluster.Namespace,
			Labels:    stroomCluster.GetLabels(),
		},
		Spec: batchv1.JobSpec{
			BackoffLimit:            &backoffLimit,
			ActiveDeadlineSeconds:   &activeDeadlineSeconds,
			TTLSecondsAfterFinished: &ttlSecondsAfterFinished,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: stroomCluster.GetLabels(),
				},
				Spec: corev1.PodSpec{
					RestartPolicy:      corev1.RestartPolicyNever,
					ServiceAccountName: stroomCluster.GetApiKeyJobServiceAccountName(),
					SecurityContext:    &nodeSet.PodSecurityContext,
					NodeSelector:       nodeSet.NodeSelector,
					Affinity:           &nodeSet.Affinity,
					Tolerations:        nodeSet.Tolerations,
					Containers: []corev1.Container{{
						Name:            ApiKeyJobContainerName,
						Image:           stroomCluster.Spec.Image.String(),
						ImagePullPolicy: stroomCluster.Spec.ImagePullPolicy,
						// Args rather than Command, so the image entrypoint runs the script as the stroom user
						Args: []string{
							"bash",
							"/stroom/scripts/" + ApiKeyJobScriptName,
						},
						Env:             env,
						VolumeMounts:    volumeMounts,
						SecurityContext: &nodeSet.SecurityContext,
						Resources: corev1.ResourceRequirements{
							Requests: corev1.ResourceList{
								corev1.ResourceCPU:    resource.MustParse("250m"),
								corev1.ResourceMemory: resource.MustParse("1Gi"),
							},
							Limits: corev1.ResourceList{
								corev1.ResourceMemory: resource.MustParse("1536Mi"),
							},
						},
					}},
					Volumes: volumes,
				},
			},
		},
	}

	ctrl.SetControllerReference(stroomCluster, job, r.Scheme)
	return job
}

// createApiKeyJobServiceAccount creates the identity the API key Job runs as
func (r *StroomClusterReconciler) createApiKeyJobServiceAccount(stroomCluster *stroomv1.StroomCluster) *corev1.ServiceAccount {
	serviceAccount := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      stroomCluster.GetApiKeyJobServiceAccountName(),
			Namespace: stroomCluster.Namespace,
			Labels:    stroomCluster.GetLabels(),
		},
	}

	ctrl.SetControllerReference(stroomCluster, serviceAccount, r.Scheme)
	return serviceAccount
}

// createApiKeyJobRole allows the API key Job to write the API key into the cluster's API key Secret, and nothing else
func (r *StroomClusterReconciler) createApiKeyJobRole(stroomCluster *stroomv1.StroomCluster) *rbacv1.Role {
	role := &rbacv1.Role{
		ObjectMeta: metav1.ObjectMeta{
			Name:      stroomCluster.GetApiKeyJobServiceAccountName(),
			Namespace: stroomCluster.Namespace,
			Labels:    stroomCluster.GetLabels(),
		},
		Rules: []rbacv1.PolicyRule{{
			APIGroups:     []string{""},
			Resources:     []string{"secrets"},
			ResourceNames: []string{stroomCluster.GetApiKeySecretName()},
			Verbs:         []string{"patch"},
		}},
	}

	ctrl.SetControllerReference(stroomCluster, role, r.Scheme)
	return role
}

// createApiKeyJobRoleBinding grants the API key Job's Role to its ServiceAccount
func (r *StroomClusterReconciler) createApiKeyJobRoleBinding(stroomCluster *stroomv1.StroomCluster) *rbacv1.RoleBinding {
	name := stroomCluster.GetApiKeyJobServiceAccountName()
	roleBinding := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: stroomCluster.Namespace,
			Labels:    stroomCluster.GetLabels(),
		},
		RoleRef: rbacv1.RoleRef{
			APIGroup: rbacv1.GroupName,
			Kind:     "Role",
			Name:     name,
		},
		Subjects: []rbacv1.Subject{{
			Kind:      rbacv1.ServiceAccountKind,
			Name:      name,
			Namespace: stroomCluster.Namespace,
		}},
	}

	ctrl.SetControllerReference(stroomCluster, roleBinding, r.Scheme)
	return roleBinding
}
