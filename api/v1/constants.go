package v1

const (
	StroomClusterFinalizerName = "stroomcluster.finalizers.stroom.gchq.github.io"
	WaitNodeTasksFinalizerName = "waitnodetasks.finalizers.stroom.gchq.github.io"

	// SecretFileMode is the file mode to use for Secret volume mounts
	SecretFileMode int32 = 0400

	// RetryMigrationAnnotation re-runs a failed database migration. Set it to any value the operator hasn't
	// acted on yet, e.g. a timestamp
	RetryMigrationAnnotation = "stroom.gchq.github.io/retry-migration"

	// AllowDowngradeAnnotation, set to "true", lets a StroomCluster move to an older Stroom version
	AllowDowngradeAnnotation = "stroom.gchq.github.io/allow-downgrade"
)
