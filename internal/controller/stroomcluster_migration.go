package controller

import (
	"context"
	"crypto/sha256"
	"fmt"
	"strings"
	"time"

	"github.com/Masterminds/semver/v3"
	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// ensureDatabaseMigrated makes sure the database schema has been migrated to the Stroom version in spec.image before
// any node runs it. Returns true once the nodes can run spec.image.
func (r *StroomClusterReconciler) ensureDatabaseMigrated(ctx context.Context, stroomCluster *stroomv1.StroomCluster, dbInfo *DatabaseConnectionInfo) (bool, ctrl.Result, error) {
	logger := log.FromContext(ctx)

	seeded, err := r.seedMigratedImage(ctx, stroomCluster)
	if err != nil {
		return false, ctrl.Result{}, err
	}
	if seeded {
		logger.Info("Recorded the image the nodes already run as the migrated image", "Image", stroomCluster.Status.MigratedImage)
		if err := r.Status().Update(ctx, stroomCluster); err != nil {
			return false, ctrl.Result{}, err
		}
	}

	// Two migrations must never run at once: if the image changed during one, let it finish first
	if idle, err := r.reconcileOtherMigrationJobs(ctx, stroomCluster); err != nil {
		return false, ctrl.Result{}, err
	} else if !idle {
		// No requeue: the running Job finishing triggers the next reconcile
		return false, ctrl.Result{}, r.setMigrationCondition(ctx, stroomCluster, metav1.ConditionFalse,
			stroomv1.MigrationReasonPending, "Waiting for an earlier migration to finish before migrating to "+stroomCluster.Spec.Image.String())
	}

	target := stroomCluster.Spec.Image.String()
	if !migrationPending(stroomCluster) {
		return true, ctrl.Result{}, r.setMigrationCondition(ctx, stroomCluster, metav1.ConditionTrue,
			stroomv1.MigrationReasonSucceeded, "Database schema is migrated to "+target)
	}

	// Refuse to move to an older Stroom version, unless overridden. A fresh install has nothing to compare with.
	if migrated := stroomCluster.Status.MigratedImage; migrated != "" {
		downgrade, comparable := isDowngrade(migrated, stroomCluster.Spec.Image)
		if !comparable {
			r.Recorder.Eventf(stroomCluster, nil, corev1.EventTypeWarning, "MigrationVersionUnknown", "Migrate",
				"Can't compare the versions of %v and %v, so can't tell if this is a downgrade. Migrating anyway", migrated, target)
		} else if downgrade && stroomCluster.Annotations[stroomv1.AllowDowngradeAnnotation] != "true" {
			message := fmt.Sprintf("Refusing to downgrade from %v to %v. To allow it, set the %v annotation to \"true\"",
				migrated, target, stroomv1.AllowDowngradeAnnotation)
			r.Recorder.Eventf(stroomCluster, nil, corev1.EventTypeWarning, "DowngradeBlocked", "Migrate", "%v", message)
			// No requeue: changing the image or the annotation triggers the next reconcile
			return false, ctrl.Result{}, r.setMigrationCondition(ctx, stroomCluster, metav1.ConditionFalse,
				stroomv1.MigrationReasonDowngradeBlocked, message)
		}
	}

	// Offline: stop every node before the schema changes. A fresh install has no nodes to stop.
	if stroomCluster.Spec.UpgradeStrategy == stroomv1.OfflineUpgrade && stroomCluster.Status.MigratedImage != "" {
		stopped, err := r.stopNodesForMigration(ctx, stroomCluster)
		if err != nil {
			return false, ctrl.Result{}, err
		}
		if !stopped {
			logger.Info("Waiting for the nodes to stop before migrating", "Image", target)
			return false, ctrl.Result{RequeueAfter: 10 * time.Second}, r.setMigrationCondition(ctx, stroomCluster,
				metav1.ConditionFalse, stroomv1.MigrationReasonPending, "Stopping the nodes before migrating to "+target)
		}
	}

	return r.runMigrationJob(ctx, stroomCluster, dbInfo)
}

// seedMigratedImage fills in status.migratedImage for a cluster created before the operator tracked migrations,
// using the image its nodes already run, so upgrading the operator doesn't trigger a migration. On a fresh install
// there are no nodes, so it's left empty and the schema is created before any node starts. Returns true if it
// changed the status.
func (r *StroomClusterReconciler) seedMigratedImage(ctx context.Context, stroomCluster *stroomv1.StroomCluster) (bool, error) {
	if stroomCluster.Status.MigratedImage != "" {
		return false, nil
	}

	for i := range stroomCluster.Spec.NodeSets {
		nodeSet := &stroomCluster.Spec.NodeSets[i]
		statefulSet := appsv1.StatefulSet{}
		name := types.NamespacedName{Namespace: stroomCluster.Namespace, Name: stroomCluster.GetNodeSetName(nodeSet)}
		if err := r.Get(ctx, name, &statefulSet); err != nil {
			if errors.IsNotFound(err) {
				continue
			}
			return false, err
		}
		for _, container := range statefulSet.Spec.Template.Spec.Containers {
			if container.Name == StroomNodeContainerName {
				stroomCluster.Status.MigratedImage = container.Image
				return true, nil
			}
		}
	}
	return false, nil
}

// migrationPending returns true if spec.image differs from the image the database was last migrated with
func migrationPending(stroomCluster *stroomv1.StroomCluster) bool {
	return stroomCluster.Spec.Image.String() != stroomCluster.Status.MigratedImage
}

// isDowngrade reports whether moving from the migrated image to the target is a move to an older Stroom version.
// comparable is false if either tag isn't a version, e.g. "latest".
func isDowngrade(migratedImage string, target stroomv1.Image) (downgrade bool, comparable bool) {
	from, err := semver.NewVersion(imageTag(migratedImage))
	if err != nil {
		return false, false
	}
	to, err := semver.NewVersion(target.Tag)
	if err != nil {
		return false, false
	}
	return to.LessThan(from), true
}

// imageTag returns the tag of an image reference, as written by Image.String()
func imageTag(image string) string {
	// Only a ':' after the last '/' starts the tag, so a registry port isn't mistaken for one
	slash := strings.LastIndex(image, "/")
	if colon := strings.LastIndex(image, ":"); colon > slash {
		return image[colon+1:]
	}
	return "latest"
}

// setMigrationCondition records the state of the database migration in the DatabaseMigrated condition, writing the
// status only if something changed
func (r *StroomClusterReconciler) setMigrationCondition(ctx context.Context, stroomCluster *stroomv1.StroomCluster, status metav1.ConditionStatus, reason, message string) error {
	changed := meta.SetStatusCondition(&stroomCluster.Status.Conditions, metav1.Condition{
		Type:               stroomv1.ConditionDatabaseMigrated,
		Status:             status,
		Reason:             reason,
		Message:            message,
		ObservedGeneration: stroomCluster.Generation,
	})
	if !changed && stroomCluster.Status.ObservedGeneration == stroomCluster.Generation {
		return nil
	}
	stroomCluster.Status.ObservedGeneration = stroomCluster.Generation
	return r.Status().Update(ctx, stroomCluster)
}

// stopNodesForMigration scales every NodeSet to 0, keeping their pod templates on the old image, and returns true
// once no node pods remain. Patches only the replica count: going through reconcileNodeStatefulSet would apply the
// new image, and could delete the nodes' PVCs under a DeleteOnScaledown policy.
func (r *StroomClusterReconciler) stopNodesForMigration(ctx context.Context, stroomCluster *stroomv1.StroomCluster) (bool, error) {
	for i := range stroomCluster.Spec.NodeSets {
		nodeSet := &stroomCluster.Spec.NodeSets[i]
		statefulSet := appsv1.StatefulSet{}
		name := types.NamespacedName{Namespace: stroomCluster.Namespace, Name: stroomCluster.GetNodeSetName(nodeSet)}
		if err := r.Get(ctx, name, &statefulSet); err != nil {
			if errors.IsNotFound(err) {
				continue
			}
			return false, err
		}
		if statefulSet.Spec.Replicas != nil && *statefulSet.Spec.Replicas == 0 {
			continue
		}
		patch := client.MergeFrom(statefulSet.DeepCopy())
		var zero int32 = 0
		statefulSet.Spec.Replicas = &zero
		if err := r.Patch(ctx, &statefulSet, patch); err != nil {
			return false, err
		}
		log.FromContext(ctx).Info("Scaled NodeSet to 0 for an offline upgrade", "StatefulSet", statefulSet.Name)
	}

	// Node pods carry the NodeSet label; the CLI Jobs' pods don't, so they aren't counted
	pods := corev1.PodList{}
	if err := r.List(ctx, &pods, client.InNamespace(stroomCluster.Namespace),
		client.MatchingLabels{stroomv1.StroomClusterLabel: stroomCluster.Name},
		client.HasLabels{stroomv1.NodeSetLabel}); err != nil {
		return false, err
	}
	return len(pods.Items) == 0, nil
}

const MigrationJobContainerName = "migrate"

// migrationJobSuffix names the migration Job after its target image, so a change of image never reuses an old Job
func migrationJobSuffix(image string) string {
	hash := sha256.Sum256([]byte(image))
	return fmt.Sprintf("migrate-%x", hash[:4])
}

// createMigrationJob creates a Job that migrates the database schema to the Stroom version in spec.image
func (r *StroomClusterReconciler) createMigrationJob(stroomCluster *stroomv1.StroomCluster, dbInfo *DatabaseConnectionInfo) *batchv1.Job {
	image := stroomCluster.Spec.Image.String()
	return r.createCliJob(stroomCluster, dbInfo, cliJobOptions{
		Name:          migrationJobSuffix(image),
		ContainerName: MigrationJobContainerName,
		Image:         image,
		Args:          []string{"bash", "-c", "cd /stroom && ./start.sh migrate"},
		JavaOpts:      stroomCluster.Spec.Migration.JavaOpts,
		Resources:     stroomCluster.Spec.Migration.Resources,
		// A migration interrupted partway is never retried automatically: someone needs to look at it first
		BackoffLimit:          0,
		ActiveDeadlineSeconds: stroomCluster.Spec.Migration.ActiveDeadlineSeconds,
		// No TTL: a failed Job is kept until it's retried, for its logs, and so it isn't silently re-created
	})
}

// runMigrationJob runs the Job migrating the database to spec.image. Returns true once it has succeeded.
func (r *StroomClusterReconciler) runMigrationJob(ctx context.Context, stroomCluster *stroomv1.StroomCluster, dbInfo *DatabaseConnectionInfo) (bool, ctrl.Result, error) {
	logger := log.FromContext(ctx)
	target := stroomCluster.Spec.Image.String()

	// Jobs can't be changed once created, so get or create, never update
	job := batchv1.Job{}
	jobName := types.NamespacedName{Namespace: stroomCluster.Namespace, Name: stroomCluster.GetCliJobName(migrationJobSuffix(target))}
	if err := r.Get(ctx, jobName, &job); err != nil {
		if !errors.IsNotFound(err) {
			return false, ctrl.Result{}, err
		}
		// This Job uses up any retry requested so far, so only a request made after it starts can re-run it.
		// Recorded before creating the Job, so a crash in between can't leave an old request unused.
		stroomCluster.Status.MigrationRetry = stroomCluster.Annotations[stroomv1.RetryMigrationAnnotation]
		if err := r.Status().Update(ctx, stroomCluster); err != nil {
			return false, ctrl.Result{}, err
		}
		newJob := r.createMigrationJob(stroomCluster, dbInfo)
		logger.Info("Creating database migration Job", "Name", newJob.Name, "Image", target)
		if err := r.Create(ctx, newJob); err != nil {
			return false, ctrl.Result{}, err
		}
		return false, ctrl.Result{}, r.setMigrationCondition(ctx, stroomCluster, metav1.ConditionFalse,
			stroomv1.MigrationReasonRunning, "Migrating the database to "+target)
	}

	finished := getJobFinishedCondition(&job)
	switch {
	case finished == nil:
		// Still running. The Job's status changes trigger the next reconcile, so there's no need to poll
		return false, ctrl.Result{}, r.setMigrationCondition(ctx, stroomCluster, metav1.ConditionFalse,
			stroomv1.MigrationReasonRunning, "Migrating the database to "+target)

	case finished.Type == batchv1.JobComplete:
		logger.Info("Database migrated", "Image", target)
		// Record the migration before deleting the Job, so a crash in between can't cause it to run again
		stroomCluster.Status.MigratedImage = target
		if err := r.Status().Update(ctx, stroomCluster); err != nil {
			return false, ctrl.Result{}, err
		}
		if err := r.setMigrationCondition(ctx, stroomCluster, metav1.ConditionTrue,
			stroomv1.MigrationReasonSucceeded, "Database schema is migrated to "+target); err != nil {
			return false, ctrl.Result{}, err
		}
		return true, ctrl.Result{}, r.deleteJob(ctx, &job)

	default:
		return r.handleFailedMigration(ctx, stroomCluster, &job)
	}
}

// handleFailedMigration keeps the nodes off the new version after a failed migration, and only re-runs it when the
// retry-migration annotation is set to a value the operator hasn't acted on
func (r *StroomClusterReconciler) handleFailedMigration(ctx context.Context, stroomCluster *stroomv1.StroomCluster, job *batchv1.Job) (bool, ctrl.Result, error) {
	target := stroomCluster.Spec.Image.String()

	if retry := stroomCluster.Annotations[stroomv1.RetryMigrationAnnotation]; retry != "" && retry != stroomCluster.Status.MigrationRetry {
		log.FromContext(ctx).Info("Retrying failed database migration", "Name", job.Name, "Retry", retry)
		// The next reconcile creates a new Job, and records this request as used
		if err := r.deleteJob(ctx, job); err != nil {
			return false, ctrl.Result{}, err
		}
		return false, ctrl.Result{RequeueAfter: 5 * time.Second}, r.setMigrationCondition(ctx, stroomCluster,
			metav1.ConditionFalse, stroomv1.MigrationReasonPending, "Retrying the migration to "+target)
	}

	nodes := "No nodes start until it succeeds"
	if migrated := stroomCluster.Status.MigratedImage; migrated != "" {
		nodes = "The nodes stay on " + migrated
	}
	message := fmt.Sprintf("Migrating the database to %v failed. %v. See: kubectl logs -n %v job/%v. "+
		"To retry, set the %v annotation to a new value", target, nodes, job.Namespace, job.Name, stroomv1.RetryMigrationAnnotation)

	// Emit the Event once, when the migration first fails, rather than on every reconcile
	if current := meta.FindStatusCondition(stroomCluster.Status.Conditions, stroomv1.ConditionDatabaseMigrated); current == nil || current.Reason != stroomv1.MigrationReasonFailed {
		r.Recorder.Eventf(stroomCluster, job, corev1.EventTypeWarning, "MigrationFailed", "Migrate", "%v", message)
	}
	// No requeue: setting the annotation triggers the next reconcile
	return false, ctrl.Result{}, r.setMigrationCondition(ctx, stroomCluster, metav1.ConditionFalse,
		stroomv1.MigrationReasonFailed, message)
}

// reconcileOtherMigrationJobs deals with migration Jobs for images other than spec.image, left behind when the image
// changes during a migration. Returns false while one is still running. One that succeeded is recorded as the
// migrated image, as the schema is now on its version, so the downgrade check compares against the real version.
func (r *StroomClusterReconciler) reconcileOtherMigrationJobs(ctx context.Context, stroomCluster *stroomv1.StroomCluster) (bool, error) {
	current := stroomCluster.GetCliJobName(migrationJobSuffix(stroomCluster.Spec.Image.String()))
	prefix := stroomCluster.GetCliJobName("migrate-")

	jobs := batchv1.JobList{}
	if err := r.List(ctx, &jobs, client.InNamespace(stroomCluster.Namespace), client.MatchingLabels(stroomCluster.GetLabels())); err != nil {
		return false, err
	}
	for i := range jobs.Items {
		job := &jobs.Items[i]
		if job.Name == current || !strings.HasPrefix(job.Name, prefix) {
			continue
		}

		finished := getJobFinishedCondition(job)
		if finished == nil {
			log.FromContext(ctx).Info("Waiting for an earlier migration to finish", "Name", job.Name)
			return false, nil
		}
		if finished.Type == batchv1.JobComplete {
			if image := migrationJobImage(job); image != "" && image != stroomCluster.Status.MigratedImage {
				log.FromContext(ctx).Info("Recording an earlier migration that finished after the image changed", "Image", image)
				stroomCluster.Status.MigratedImage = image
				if err := r.Status().Update(ctx, stroomCluster); err != nil {
					return false, err
				}
			}
		}
		if err := r.deleteJob(ctx, job); err != nil {
			return false, err
		}
	}
	return true, nil
}

// migrationJobImage returns the image a migration Job migrates to
func migrationJobImage(job *batchv1.Job) string {
	for _, container := range job.Spec.Template.Spec.Containers {
		if container.Name == MigrationJobContainerName {
			return container.Image
		}
	}
	return ""
}
