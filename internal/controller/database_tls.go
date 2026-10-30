package controller

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"

	"github.com/go-sql-driver/mysql"
	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
)

const (
	DbCaVolumeName         = "db-ca"
	DbTruststoreVolumeName = "db-truststore"
	DbTruststoreMountPath  = "/stroom/db-tls"
	DbTruststoreFileName   = "truststore.p12"
	// The truststore only holds public CA certificates, so its password protects nothing; Java needs one to read it
	dbTruststorePassword = "db-truststore"
)

// jdbcSslModes maps each TLS mode to MySQL Connector/J's sslMode
var jdbcSslModes = map[stroomv1.DatabaseTlsMode]string{
	stroomv1.DatabaseTlsDisabled:       "DISABLED",
	stroomv1.DatabaseTlsPreferred:      "PREFERRED",
	stroomv1.DatabaseTlsRequired:       "REQUIRED",
	stroomv1.DatabaseTlsVerifyCA:       "VERIFY_CA",
	stroomv1.DatabaseTlsVerifyIdentity: "VERIFY_IDENTITY",
}

// jdbcTlsParameters returns the JDBC URL parameters for the connection's TLS settings, each starting with `&`. With no
// settings, none are returned, so Connector/J uses its default (PREFERRED).
func jdbcTlsParameters(dbTls *stroomv1.DatabaseTls) string {
	if dbTls == nil {
		return ""
	}
	parameters := "&sslMode=" + jdbcSslModes[dbTls.GetMode()]
	if dbTls.CaCertificates != nil {
		// The path has no characters with a meaning in URLs, so it isn't encoded
		parameters += "&trustCertificateKeyStoreUrl=file:" + DbTruststoreMountPath + "/" + DbTruststoreFileName +
			"&trustCertificateKeyStoreType=PKCS12&trustCertificateKeyStorePassword=" + dbTruststorePassword
	}
	return parameters
}

// dbTruststore returns what a Stroom Pod needs to trust the database server's CA certificates, if the connection
// names any: the volumes, an init container that turns the PEM certificates into a PKCS12 truststore for Java, and
// the truststore's mount
func dbTruststore(stroomCluster *stroomv1.StroomCluster, dbInfo *DatabaseConnectionInfo, securityContext corev1.SecurityContext) ([]corev1.Volume, []corev1.Container, []corev1.VolumeMount) {
	if dbInfo.Tls == nil || dbInfo.Tls.CaCertificates == nil {
		return nil, nil, nil
	}
	caCertificates := dbInfo.Tls.CaCertificates
	volumes := []corev1.Volume{{
		Name: DbCaVolumeName,
		VolumeSource: corev1.VolumeSource{
			ConfigMap: &corev1.ConfigMapVolumeSource{
				LocalObjectReference: corev1.LocalObjectReference{Name: caCertificates.ConfigMapName},
				Items:                []corev1.KeyToPath{{Key: caCertificates.Key, Path: "ca.crt"}},
			},
		},
	}, {
		Name:         DbTruststoreVolumeName,
		VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
	}}
	initContainers := []corev1.Container{{
		Name:            "create-db-truststore",
		Image:           stroomCluster.Spec.Image.String(),
		ImagePullPolicy: stroomCluster.Spec.ImagePullPolicy,
		SecurityContext: containerSecurityContext(securityContext),
		Command: []string{
			"sh",
			"-c",
			// The file is readable by all, as it holds public certificates, and Stroom may run as a different user
			fmt.Sprintf("openssl pkcs12 -export -nokeys -in /opt/db-ca/ca.crt -out /data/%[1]v -passout pass:%[2]v -jdktrust anyExtendedKeyUsage && chmod 0444 /data/%[1]v",
				DbTruststoreFileName, dbTruststorePassword),
		},
		VolumeMounts: []corev1.VolumeMount{{
			Name:      DbCaVolumeName,
			MountPath: "/opt/db-ca",
			ReadOnly:  true,
		}, {
			Name:      DbTruststoreVolumeName,
			MountPath: "/data",
		}},
	}}
	mounts := []corev1.VolumeMount{{
		Name:      DbTruststoreVolumeName,
		MountPath: DbTruststoreMountPath,
		ReadOnly:  true,
	}}
	return volumes, initContainers, mounts
}

// configureDatabaseTls sets how the operator's own connection to the database uses TLS, matching Stroom's. Unset, TLS
// is used if the server supports it, without checking the server's certificate. caCertificates are the PEM
// certificates of the CAs to trust; with none, the system's are trusted. host is the name the server's certificate
// must be for, with VerifyIdentity.
func configureDatabaseTls(config *mysql.Config, host string, dbTls *stroomv1.DatabaseTls, caCertificates []byte) error {
	if dbTls == nil {
		config.TLSConfig = "preferred"
		return nil
	}

	var roots *x509.CertPool
	if len(caCertificates) > 0 {
		roots = x509.NewCertPool()
		if !roots.AppendCertsFromPEM(caCertificates) {
			return fmt.Errorf("no PEM certificates found in the database CA certificates")
		}
	}

	switch dbTls.GetMode() {
	case stroomv1.DatabaseTlsDisabled:
		config.TLSConfig = "false"
	case stroomv1.DatabaseTlsPreferred:
		config.TLSConfig = "preferred"
	case stroomv1.DatabaseTlsRequired:
		config.TLSConfig = "skip-verify"
	case stroomv1.DatabaseTlsVerifyCA:
		// Check the certificate chain, but not the host name. Go's TLS client can't do that by itself, so its own check
		// is skipped and the chain verified here.
		config.TLS = &tls.Config{
			MinVersion:         tls.VersionTLS12,
			InsecureSkipVerify: true,
			VerifyConnection: func(state tls.ConnectionState) error {
				if len(state.PeerCertificates) == 0 {
					return fmt.Errorf("the database server sent no certificate")
				}
				options := x509.VerifyOptions{Roots: roots, Intermediates: x509.NewCertPool()}
				for _, certificate := range state.PeerCertificates[1:] {
					options.Intermediates.AddCert(certificate)
				}
				_, err := state.PeerCertificates[0].Verify(options)
				return err
			},
		}
	case stroomv1.DatabaseTlsVerifyIdentity:
		config.TLS = &tls.Config{
			MinVersion: tls.VersionTLS12,
			RootCAs:    roots,
			ServerName: host,
		}
	default:
		return fmt.Errorf("unknown database TLS mode '%v'", dbTls.Mode)
	}
	return nil
}
