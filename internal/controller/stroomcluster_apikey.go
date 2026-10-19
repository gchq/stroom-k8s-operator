package controller

import (
	"context"
	"time"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	// Secret data item containing the API key. Must match the key written by the API key script.
	ApiKeySecretDataKey    = "apiKey"
	ApiKeyJobScriptName    = "create-stroom-api-key.sh"
	ApiKeyJobContainerName = "create-api-key"
	ApiKeyJobRetryDelay    = 5 * time.Minute
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
					RestartPolicy: corev1.RestartPolicyNever,
					// Run as the Stroom node ServiceAccount, so the Job is subject to the same security constraints (e.g.
					// OpenShift SCCs) as the nodes, without needing any extra setup
					ServiceAccountName: stroomCluster.GetBaseName(),
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

// createApiKeyWriterRole allows the API key Job to write the API key into the cluster's API key Secret, and nothing else
func (r *StroomClusterReconciler) createApiKeyWriterRole(stroomCluster *stroomv1.StroomCluster) *rbacv1.Role {
	role := &rbacv1.Role{
		ObjectMeta: metav1.ObjectMeta{
			Name:      stroomCluster.GetApiKeyWriterRoleName(),
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

// createApiKeyWriterRoleBinding grants the API key Job's Role to clusters ServiceAccount
func (r *StroomClusterReconciler) createApiKeyWriterRoleBinding(stroomCluster *stroomv1.StroomCluster) *rbacv1.RoleBinding {
	name := stroomCluster.GetApiKeyWriterRoleName()
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
			Name:      stroomCluster.GetBaseName(),
			Namespace: stroomCluster.Namespace,
		}},
	}

	ctrl.SetControllerReference(stroomCluster, roleBinding, r.Scheme)
	return roleBinding
}

// ensureApiKey makes sure the cluster's API key Secret contains a key, running the API key Job to create one if
// needed. Only applies when the cluster uses Stroom's internal identity provider.
// A non-zero Result means provisioning is still in progress, and the caller should return it.
func (r *StroomClusterReconciler) ensureApiKey(ctx context.Context, stroomCluster *stroomv1.StroomCluster, dbInfo *DatabaseConnectionInfo) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	if stroomCluster.Spec.GetIdentityProviderType() != stroomv1.InternalIdp {
		return ctrl.Result{}, nil
	}

	// The Secret is created empty and filled in by the Job. It is create-only, so the operator never overwrites the key.
	secret := corev1.Secret{}
	secretName := types.NamespacedName{Namespace: stroomCluster.Namespace, Name: stroomCluster.GetApiKeySecretName()}
	if err := r.Get(ctx, secretName, &secret); err != nil {
		if !errors.IsNotFound(err) {
			return ctrl.Result{}, err
		}
		newSecret := r.createApiKeySecret(stroomCluster)
		logger.Info("Creating API key Secret", "Namespace", newSecret.Namespace, "Name", newSecret.Name)
		if err := r.Create(ctx, newSecret); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: time.Second}, nil
	}
	if len(secret.Data[ApiKeySecretDataKey]) > 0 {
		return ctrl.Result{}, nil
	}

	if err := r.reconcileApiKeyRbac(ctx, stroomCluster); err != nil {
		return ctrl.Result{}, err
	}

	// Jobs can't be changed once created, so get or create, never update
	job := batchv1.Job{}
	jobName := types.NamespacedName{Namespace: stroomCluster.Namespace, Name: stroomCluster.GetCliJobName("api-key")}
	if err := r.Get(ctx, jobName, &job); err != nil {
		if !errors.IsNotFound(err) {
			return ctrl.Result{}, err
		}
		newJob := r.createApiKeyJob(stroomCluster, dbInfo)
		logger.Info("Creating API key Job", "Namespace", newJob.Namespace, "Name", newJob.Name)
		if err := r.Create(ctx, newJob); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
	}

	finished := getJobFinishedCondition(&job)
	switch {
	case finished == nil:
		// Still running
		return ctrl.Result{RequeueAfter: 10 * time.Second}, nil

	case finished.Type == batchv1.JobComplete:
		// The Job succeeded earlier, but the Secret is empty again (e.g. it was deleted), so run it again
		logger.Info("API key Secret is empty. Re-running API key Job", "Name", job.Name)
		if err := r.deleteJob(ctx, &job); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil

	default:
		// Failed. Keep it for a while so its logs can be inspected, then retry.
		if wait := time.Until(finished.LastTransitionTime.Add(ApiKeyJobRetryDelay)); wait > 0 {
			r.Recorder.Eventf(stroomCluster, &job, corev1.EventTypeWarning, "ApiKeyJobFailed", "CreateApiKey",
				"API key Job failed, retrying in %v. See: kubectl logs -n %v job/%v", wait.Round(time.Second), job.Namespace, job.Name)
			return ctrl.Result{RequeueAfter: wait}, nil
		}
		logger.Info("Retrying failed API key Job", "Name", job.Name)
		if err := r.deleteJob(ctx, &job); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}
}

// createApiKeySecret creates the empty Secret the API key Job writes the key into
func (r *StroomClusterReconciler) createApiKeySecret(stroomCluster *stroomv1.StroomCluster) *corev1.Secret {
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      stroomCluster.GetApiKeySecretName(),
			Namespace: stroomCluster.Namespace,
			Labels:    stroomCluster.GetLabels(),
		},
		Type: corev1.SecretTypeOpaque,
	}

	ctrl.SetControllerReference(stroomCluster, secret, r.Scheme)
	return secret
}

// reconcileApiKeyRbac creates or updates the Role and RoleBinding that allow the API key Job to write the API key Secret
func (r *StroomClusterReconciler) reconcileApiKeyRbac(ctx context.Context, stroomCluster *stroomv1.StroomCluster) error {
	newRole := r.createApiKeyWriterRole(stroomCluster)
	role := rbacv1.Role{ObjectMeta: metav1.ObjectMeta{Name: newRole.Name, Namespace: newRole.Namespace}}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, &role, func() error {
		role.Labels = newRole.Labels
		role.OwnerReferences = newRole.OwnerReferences
		role.Rules = newRole.Rules
		return nil
	}); err != nil {
		return err
	}

	newRoleBinding := r.createApiKeyWriterRoleBinding(stroomCluster)
	roleBinding := rbacv1.RoleBinding{ObjectMeta: metav1.ObjectMeta{Name: newRoleBinding.Name, Namespace: newRoleBinding.Namespace}}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, &roleBinding, func() error {
		roleBinding.Labels = newRoleBinding.Labels
		roleBinding.OwnerReferences = newRoleBinding.OwnerReferences
		roleBinding.RoleRef = newRoleBinding.RoleRef
		roleBinding.Subjects = newRoleBinding.Subjects
		return nil
	})
	return err
}

// getJobFinishedCondition returns the Job's Complete or Failed condition, or nil if it is still running
func getJobFinishedCondition(job *batchv1.Job) *batchv1.JobCondition {
	for i := range job.Status.Conditions {
		condition := &job.Status.Conditions[i]
		if (condition.Type == batchv1.JobComplete || condition.Type == batchv1.JobFailed) && condition.Status == corev1.ConditionTrue {
			return condition
		}
	}
	return nil
}

// deleteJob deletes a Job along with its pods
func (r *StroomClusterReconciler) deleteJob(ctx context.Context, job *batchv1.Job) error {
	// Without Background propagation, deleting a Job leaves its pods behind
	err := r.Delete(ctx, job, client.PropagationPolicy(metav1.DeletePropagationBackground))
	return client.IgnoreNotFound(err)
}

// warnOnIdentityProviderConflict emits a Warning Event if ExtraEnv sets IDENTITY_PROVIDER_TYPE differently from
// spec.identityProviderType, as Stroom would then use a different identity provider to the one the operator expects
func (r *StroomClusterReconciler) warnOnIdentityProviderConflict(stroomCluster *stroomv1.StroomCluster) {
	expected := string(stroomCluster.Spec.GetIdentityProviderType())
	for _, envVar := range stroomCluster.Spec.ExtraEnv {
		if envVar.Name == "IDENTITY_PROVIDER_TYPE" && (envVar.ValueFrom != nil || envVar.Value != expected) {
			r.Recorder.Eventf(stroomCluster, nil, corev1.EventTypeWarning, "IdentityProviderTypeConflict", "Reconcile",
				"extraEnv sets IDENTITY_PROVIDER_TYPE, overriding spec.identityProviderType (%v). "+
					"Set spec.identityProviderType instead and remove it from extraEnv", expected)
		}
	}
}
