package controller

import (
	"fmt"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
)

// Defaults for a CLI Job's process, which needs far less memory than a Stroom node
const cliJobDefaultJavaOpts = "-Xms128m -Xmx1g"

// cliJobOptions holds what differs between the Jobs that run the Stroom CLI
type cliJobOptions struct {
	// Suffix for the Job name, passed to GetCliJobName
	Name          string
	ContainerName string
	Image         string
	Args          []string
	// Job-specific environment, added after ExtraEnv so it takes precedence
	Env []corev1.EnvVar
	// Job-specific volumes and mounts, added before the shared ones
	Volumes      []corev1.Volume
	VolumeMounts []corev1.VolumeMount
	// Empty means cliJobDefaultJavaOpts
	JavaOpts string
	// Empty means the default CLI resources
	Resources               corev1.ResourceRequirements
	BackoffLimit            int32
	ActiveDeadlineSeconds   *int64
	TTLSecondsAfterFinished *int32
}

// createCliJob creates a Job that runs a Stroom CLI command against the cluster's database, with the same config,
// security and scheduling settings as the first NodeSet
func (r *StroomClusterReconciler) createCliJob(stroomCluster *stroomv1.StroomCluster, dbInfo *DatabaseConnectionInfo, opts cliJobOptions) *batchv1.Job {
	// The CRD requires at least one NodeSet
	nodeSet := &stroomCluster.Spec.NodeSets[0]

	javaOpts := opts.JavaOpts
	if javaOpts == "" {
		javaOpts = cliJobDefaultJavaOpts
	}

	env := r.getStroomCommonEnv(stroomCluster, dbInfo)
	env = append(env, r.getIdentityProviderEnv(stroomCluster))
	env = append(env, stroomCluster.Spec.ExtraEnv...)
	// Job-specific variables come last, so they take precedence over any in ExtraEnv
	env = append(env, opts.Env...)
	env = append(env, []corev1.EnvVar{{
		Name:  "JAVA_OPTS",
		Value: javaOpts,
	}, {
		// Stroom config derives URIs (including the processing user's token issuer) from the node identity, so the Job
		// presents itself as the first node of the first NodeSet
		Name:  "STROOM_NODE",
		Value: stroomCluster.GetNodeSetName(nodeSet) + "-0",
	}, {
		Name:  "POD_HOSTNAME",
		Value: stroomCluster.GetNodeSetName(nodeSet) + "-0",
	}, {
		Name:  "POD_SUBDOMAIN",
		Value: fmt.Sprintf("%v.%v.svc.cluster.local", stroomCluster.GetNodeSetHeadlessServiceName(nodeSet), stroomCluster.Namespace),
	}, {
		Name:  "API_GATEWAY_HOST",
		Value: stroomCluster.Spec.Ingress.HostName,
	}}...)

	volumes := []corev1.Volume{*r.createStaticContentVolume(stroomCluster)}
	volumes = append(volumes, opts.Volumes...)
	volumes = append(volumes, corev1.Volume{
		Name:         "stroom-tmp",
		VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
	}, corev1.Volume{
		Name:         "stroom-logs",
		VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
	})
	if !stroomCluster.Spec.ConfigMapRef.IsZero() {
		volumes = append(volumes, *r.createConfigOverrideVolume(stroomCluster))
	}

	volumeMounts := append([]corev1.VolumeMount{}, opts.VolumeMounts...)
	volumeMounts = append(volumeMounts, corev1.VolumeMount{
		Name:      "stroom-tmp",
		MountPath: "/stroom/tmp",
	}, corev1.VolumeMount{
		Name:      "stroom-logs",
		MountPath: "/stroom/logs",
	})
	r.appendConfigVolumeMounts(stroomCluster, &volumeMounts)

	resources := opts.Resources
	if len(resources.Requests) == 0 && len(resources.Limits) == 0 {
		resources = corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("250m"),
				corev1.ResourceMemory: resource.MustParse("1Gi"),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceMemory: resource.MustParse("1536Mi"),
			},
		}
	}

	backoffLimit := opts.BackoffLimit
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      stroomCluster.GetCliJobName(opts.Name),
			Namespace: stroomCluster.Namespace,
			Labels:    stroomCluster.GetLabels(),
		},
		Spec: batchv1.JobSpec{
			BackoffLimit:            &backoffLimit,
			ActiveDeadlineSeconds:   opts.ActiveDeadlineSeconds,
			TTLSecondsAfterFinished: opts.TTLSecondsAfterFinished,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: stroomCluster.GetLabels(),
				},
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					// Run as the Stroom node ServiceAccount, so the Job is subject to the same security constraints (e.g.
					// OpenShift SCCs) as the nodes, without needing any extra setup
					ServiceAccountName: stroomCluster.GetBaseName(),
					SecurityContext:    &nodeSet.PodSecurityContext,
					NodeSelector:       nodeSet.NodeSelector,
					Affinity:           &nodeSet.Affinity,
					Tolerations:        nodeSet.Tolerations,
					Containers: []corev1.Container{{
						Name:            opts.ContainerName,
						Image:           opts.Image,
						ImagePullPolicy: stroomCluster.Spec.ImagePullPolicy,
						// Args rather than Command, so the image entrypoint runs as the stroom user
						Args:            opts.Args,
						Env:             env,
						VolumeMounts:    volumeMounts,
						SecurityContext: &nodeSet.SecurityContext,
						Resources:       resources,
					}},
					Volumes: volumes,
				},
			},
		},
	}

	ctrl.SetControllerReference(stroomCluster, job, r.Scheme)
	return job
}
