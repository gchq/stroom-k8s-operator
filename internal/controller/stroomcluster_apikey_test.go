package controller

import (
	"strconv"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestGetApiKeyRenewalTime(t *testing.T) {
	expires := time.Now().Add(365 * 24 * time.Hour).Truncate(time.Second)

	tests := []struct {
		name        string
		annotations map[string]string
		want        time.Time
	}{
		{"valid expiry", map[string]string{ApiKeyExpiresAnnotation: strconv.FormatInt(expires.Unix(), 10)}, expires.Add(-ApiKeyRenewBefore)},
		{"missing annotation", nil, time.Time{}},
		{"invalid annotation", map[string]string{ApiKeyExpiresAnnotation: "soon"}, time.Time{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Annotations: tt.annotations}}
			if got := getApiKeyRenewalTime(secret); !got.Equal(tt.want) {
				t.Errorf("getApiKeyRenewalTime() = %v, want %v", got, tt.want)
			}
		})
	}
}
