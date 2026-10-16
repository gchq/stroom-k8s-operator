package controller

import (
	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
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
