package controller

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("Database TLS", func() {

	caRef := &stroomv1.ConfigMapKeyRef{ConfigMapName: "rds-ca", Key: "global-bundle.pem"}

	Context("ToJdbcConnectionString()", func() {
		jdbcParameters := func(dbTls *stroomv1.DatabaseTls) url.Values {
			dbInfo := &DatabaseConnectionInfo{ServerAddress: stroomv1.ServerAddress{Host: "db.example.com", Port: 3306, Tls: dbTls}}
			jdbcUrl := dbInfo.ToJdbcConnectionString("stroom")
			Expect(jdbcUrl).To(HavePrefix("jdbc:mysql://db.example.com:3306/stroom?serverTimezone=UTC&useUnicode=yes&characterEncoding=UTF-8"))
			values, err := url.ParseQuery(jdbcUrl[strings.Index(jdbcUrl, "?")+1:])
			Expect(err).ToNot(HaveOccurred())
			return values
		}

		It("should leave TLS to Connector/J's default without settings", func() {
			Expect(jdbcParameters(nil)).ToNot(HaveKey("sslMode"))
		})
		It("should set each mode", func() {
			Expect(jdbcParameters(&stroomv1.DatabaseTls{Mode: stroomv1.DatabaseTlsRequired}).Get("sslMode")).To(Equal("REQUIRED"))
			Expect(jdbcParameters(&stroomv1.DatabaseTls{Mode: stroomv1.DatabaseTlsVerifyCA}).Get("sslMode")).To(Equal("VERIFY_CA"))
			Expect(jdbcParameters(&stroomv1.DatabaseTls{}).Get("sslMode")).To(Equal("VERIFY_IDENTITY"), "the CRD default")
		})
		It("should trust the truststore made from the CA certificates", func() {
			values := jdbcParameters(&stroomv1.DatabaseTls{Mode: stroomv1.DatabaseTlsVerifyIdentity, CaCertificates: caRef})
			Expect(values.Get("trustCertificateKeyStoreUrl")).To(Equal("file:/stroom/db-tls/truststore.p12"))
			Expect(values.Get("trustCertificateKeyStoreType")).To(Equal("PKCS12"))
			Expect(values.Get("trustCertificateKeyStorePassword")).ToNot(BeEmpty())
		})
	})

	Context("dbTruststore()", func() {
		cluster := &stroomv1.StroomCluster{Spec: stroomv1.StroomClusterSpec{Image: stroomv1.Image{Repository: "gchq/stroom", Tag: "v7.14.0"}}}

		It("should add nothing without CA certificates", func() {
			dbInfo := &DatabaseConnectionInfo{ServerAddress: stroomv1.ServerAddress{Tls: &stroomv1.DatabaseTls{Mode: stroomv1.DatabaseTlsRequired}}}
			volumes, initContainers, mounts := dbTruststore(cluster, dbInfo, corev1.SecurityContext{})
			Expect(volumes).To(BeEmpty())
			Expect(initContainers).To(BeEmpty())
			Expect(mounts).To(BeEmpty())
		})
		It("should build the truststore from the ConfigMap key, with the given security settings", func() {
			runAsNonRoot := true
			dbInfo := &DatabaseConnectionInfo{ServerAddress: stroomv1.ServerAddress{Tls: &stroomv1.DatabaseTls{CaCertificates: caRef}}}
			volumes, initContainers, mounts := dbTruststore(cluster, dbInfo, corev1.SecurityContext{RunAsNonRoot: &runAsNonRoot})

			Expect(volumes).To(HaveLen(2))
			Expect(volumes[0].ConfigMap.Name).To(Equal("rds-ca"))
			Expect(volumes[0].ConfigMap.Items).To(Equal([]corev1.KeyToPath{{Key: "global-bundle.pem", Path: "ca.crt"}}))
			Expect(volumes[1].EmptyDir).ToNot(BeNil())

			Expect(initContainers).To(HaveLen(1))
			Expect(initContainers[0].Image).To(Equal("gchq/stroom:v7.14.0"))
			Expect(*initContainers[0].SecurityContext.RunAsNonRoot).To(BeTrue())
			Expect(*initContainers[0].SecurityContext.AllowPrivilegeEscalation).To(BeFalse())

			Expect(mounts).To(Equal([]corev1.VolumeMount{{Name: DbTruststoreVolumeName, MountPath: "/stroom/db-tls", ReadOnly: true}}))
		})
	})

	Context("configureDatabaseTls()", func() {
		ca, caPem := newTestCa("Test DB CA")
		otherCa, otherCaPem := newTestCa("Other CA")
		serverCertificate := ca.issue("db.example.com")

		// handshake connects a client with the operator's TLS settings to a server with the given certificate
		handshake := func(dbTls *stroomv1.DatabaseTls, caCertificates []byte, certificate tls.Certificate, host string) error {
			config := mysql.NewConfig()
			Expect(configureDatabaseTls(config, host, dbTls, caCertificates)).To(Succeed())
			Expect(config.TLS).ToNot(BeNil())

			clientConn, serverConn := net.Pipe()
			defer clientConn.Close()
			defer serverConn.Close()
			go func() {
				_ = tls.Server(serverConn, &tls.Config{Certificates: []tls.Certificate{certificate}}).Handshake()
			}()
			Expect(clientConn.SetDeadline(time.Now().Add(10 * time.Second))).To(Succeed())
			return tls.Client(clientConn, config.TLS).Handshake()
		}

		It("should keep upstream's behaviour without settings", func() {
			config := mysql.NewConfig()
			Expect(configureDatabaseTls(config, "db.example.com", nil, nil)).To(Succeed())
			Expect(config.TLSConfig).To(Equal("preferred"))
		})
		It("should use the driver's settings for modes that don't check the certificate", func() {
			for mode, expected := range map[stroomv1.DatabaseTlsMode]string{
				stroomv1.DatabaseTlsDisabled:  "false",
				stroomv1.DatabaseTlsPreferred: "preferred",
				stroomv1.DatabaseTlsRequired:  "skip-verify",
			} {
				config := mysql.NewConfig()
				Expect(configureDatabaseTls(config, "db.example.com", &stroomv1.DatabaseTls{Mode: mode}, caPem)).To(Succeed())
				Expect(config.TLSConfig).To(Equal(expected), string(mode))
				Expect(config.TLS).To(BeNil(), string(mode))
			}
		})
		It("should refuse CA certificates that aren't PEM", func() {
			config := mysql.NewConfig()
			Expect(configureDatabaseTls(config, "db.example.com", &stroomv1.DatabaseTls{CaCertificates: caRef}, []byte("not PEM"))).ToNot(Succeed())
		})

		It("should check the CA and host name with VerifyIdentity", func() {
			verifyIdentity := &stroomv1.DatabaseTls{Mode: stroomv1.DatabaseTlsVerifyIdentity, CaCertificates: caRef}
			Expect(handshake(verifyIdentity, caPem, serverCertificate, "db.example.com")).To(Succeed())
			Expect(handshake(verifyIdentity, caPem, serverCertificate, "other.example.com")).ToNot(Succeed(), "wrong host name")
			Expect(handshake(verifyIdentity, otherCaPem, serverCertificate, "db.example.com")).ToNot(Succeed(), "untrusted CA")
		})
		It("should check the CA, but not the host name, with VerifyCA", func() {
			verifyCa := &stroomv1.DatabaseTls{Mode: stroomv1.DatabaseTlsVerifyCA, CaCertificates: caRef}
			Expect(handshake(verifyCa, caPem, serverCertificate, "db.example.com")).To(Succeed())
			Expect(handshake(verifyCa, caPem, serverCertificate, "other.example.com")).To(Succeed(), "host name not checked")
			Expect(handshake(verifyCa, otherCaPem, serverCertificate, "db.example.com")).ToNot(Succeed(), "untrusted CA")
			Expect(handshake(verifyCa, caPem, otherCa.issue("db.example.com"), "db.example.com")).ToNot(Succeed(), "certificate from another CA")
		})
	})
})

type testCa struct {
	certificate *x509.Certificate
	key         *ecdsa.PrivateKey
}

// newTestCa creates a self-signed CA, returning it and its certificate as PEM
func newTestCa(name string) (*testCa, []byte) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	Expect(err).ToNot(HaveOccurred())
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: name},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	Expect(err).ToNot(HaveOccurred())
	certificate, err := x509.ParseCertificate(der)
	Expect(err).ToNot(HaveOccurred())
	return &testCa{certificate: certificate, key: key}, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

// issue returns a server certificate for the host, issued by the CA
func (ca *testCa) issue(host string) tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	Expect(err).ToNot(HaveOccurred())
	template := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca.certificate, &key.PublicKey, ca.key)
	Expect(err).ToNot(HaveOccurred())
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}
