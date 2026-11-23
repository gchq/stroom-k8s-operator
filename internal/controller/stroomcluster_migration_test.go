package controller

import (
	"regexp"
	"testing"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

func TestImageTag(t *testing.T) {
	tests := []struct {
		name  string
		image string
		want  string
	}{
		{"tag", "gchq/stroom:v7.13.2", "v7.13.2"},
		{"registry port is not a tag", "registry:5000/gchq/stroom:v7.13.2", "v7.13.2"},
		{"registry port without a tag", "registry:5000/gchq/stroom", "latest"},
		{"no tag", "stroom", "latest"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := imageTag(tt.image); got != tt.want {
				t.Errorf("imageTag(%q) = %q, want %q", tt.image, got, tt.want)
			}
		})
	}
}

func TestIsDowngrade(t *testing.T) {
	tests := []struct {
		name           string
		migratedImage  string
		targetTag      string
		wantDowngrade  bool
		wantComparable bool
	}{
		{"older patch", "gchq/stroom:v7.13.2", "v7.13.1", true, true},
		{"newer patch", "gchq/stroom:v7.13.1", "v7.13.2", false, true},
		{"same version", "gchq/stroom:v7.13.2", "v7.13.2", false, true},
		{"pre-release of the migrated version", "gchq/stroom:7.14.0", "v7.14.0-beta.1", true, true},
		{"release after its pre-release", "gchq/stroom:v7.14.0-beta.1", "7.14.0", false, true},
		{"registry port", "registry:5000/gchq/stroom:v7.14.0", "v7.13.2", true, true},
		{"target not a version", "gchq/stroom:v7.13.2", "latest", false, false},
		{"migrated not a version", "gchq/stroom:latest", "v7.13.2", false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			downgrade, comparable := isDowngrade(tt.migratedImage, stroomv1.Image{Repository: "gchq/stroom", Tag: tt.targetTag})
			if downgrade != tt.wantDowngrade || comparable != tt.wantComparable {
				t.Errorf("isDowngrade(%q, %q) = %v, %v; want %v, %v",
					tt.migratedImage, tt.targetTag, downgrade, comparable, tt.wantDowngrade, tt.wantComparable)
			}
		})
	}
}

func TestMigrationJobSuffix(t *testing.T) {
	suffix := migrationJobSuffix("gchq/stroom:v7.13.2")

	if again := migrationJobSuffix("gchq/stroom:v7.13.2"); again != suffix {
		t.Errorf("same image gave %q then %q, want the same suffix", suffix, again)
	}
	if other := migrationJobSuffix("gchq/stroom:v7.13.1"); other == suffix {
		t.Errorf("different images both gave %q, want different suffixes", suffix)
	}
	// Part of a Job name, so it must be a valid, short DNS label
	if !regexp.MustCompile(`^migrate-[0-9a-f]{8}$`).MatchString(suffix) {
		t.Errorf("suffix %q isn't 'migrate-' followed by 8 hex characters", suffix)
	}
}

func TestMigrationPending(t *testing.T) {
	tests := []struct {
		name          string
		tag           string
		migratedImage string
		want          bool
	}{
		{"fresh install", "v7.13.2", "", true},
		{"up to date", "v7.13.2", "gchq/stroom:v7.13.2", false},
		{"new version", "v7.13.2", "gchq/stroom:v7.13.1", true},
		{"empty tag means latest", "", "gchq/stroom:latest", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cluster := &stroomv1.StroomCluster{
				Spec:   stroomv1.StroomClusterSpec{Image: stroomv1.Image{Repository: "gchq/stroom", Tag: tt.tag}},
				Status: stroomv1.StroomClusterStatus{MigratedImage: tt.migratedImage},
			}
			if got := migrationPending(cluster); got != tt.want {
				t.Errorf("migrationPending() = %v, want %v", got, tt.want)
			}
		})
	}
}
