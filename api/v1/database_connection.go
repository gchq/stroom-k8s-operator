package v1

type DatabaseServerRef struct {
	// If specified, point to an operator-managed DatabaseServer object
	// +optional
	ServerRef ResourceRef `json:"serverRef,omitempty"`
	// Alternatively, if the following parameters are provided, point directly to a DB by its TCP address.
	// This allows external database instances to be used in place of an operator-managed one.
	ServerAddress ServerAddress `json:"serverAddress,omitempty"`
	// UserName is the name of the Stroom database user to use when connecting to the server.
	// A corresponding key should exist in the provided Secret referenced by SecretName.
	// +kubebuilder:default:=stroomuser
	UserName string `json:"userName,omitempty"`
}

type ServerAddress struct {
	// Host is the hostname or IP of the database server
	Host string `json:"host,omitempty"`
	// Port number the database server is listening on
	// +kubebuilder:default:=3306
	Port int32 `json:"port,omitempty"`
	// SecretName is the name of the Secret containing the database user's password, under a key named after the
	// user (`userName`, by default `stroomuser`)
	SecretName string `json:"secretName,omitempty"`
	// Tls sets how Stroom and the operator use TLS on their connections to the database server. Unset, they use TLS if
	// the server supports it, without checking the server's certificate. A DatabaseBackup doesn't use these settings:
	// mysqldump uses TLS if the server supports it.
	// +optional
	Tls *DatabaseTls `json:"tls,omitempty"`
}

// DatabaseTlsMode is how a database connection uses TLS, as MySQL's `sslMode`
// +kubebuilder:validation:Enum=Disabled;Preferred;Required;VerifyCA;VerifyIdentity
type DatabaseTlsMode string

const (
	// DatabaseTlsDisabled doesn't use TLS
	DatabaseTlsDisabled DatabaseTlsMode = "Disabled"
	// DatabaseTlsPreferred uses TLS if the server supports it, without checking the server's certificate
	DatabaseTlsPreferred DatabaseTlsMode = "Preferred"
	// DatabaseTlsRequired requires TLS, without checking the server's certificate
	DatabaseTlsRequired DatabaseTlsMode = "Required"
	// DatabaseTlsVerifyCA requires TLS and a server certificate issued by a trusted CA
	DatabaseTlsVerifyCA DatabaseTlsMode = "VerifyCA"
	// DatabaseTlsVerifyIdentity requires TLS and a server certificate issued by a trusted CA for the server's host name
	DatabaseTlsVerifyIdentity DatabaseTlsMode = "VerifyIdentity"
)

type DatabaseTls struct {
	// Mode is how connections use TLS
	// +kubebuilder:default:=VerifyIdentity
	Mode DatabaseTlsMode `json:"mode,omitempty"`
	// CaCertificates selects a ConfigMap key holding the PEM certificates of the CAs to trust for the server's
	// certificate, such as the Amazon RDS global bundle or a trust-manager Bundle. Unset, the CAs trusted by the Java
	// runtime (for Stroom) and the operator's image are used.
	// +optional
	CaCertificates *ConfigMapKeyRef `json:"caCertificates,omitempty"`
}

// GetMode returns the TLS mode, with the CRD default if it isn't set
func (in *DatabaseTls) GetMode() DatabaseTlsMode {
	if in.Mode == "" {
		return DatabaseTlsVerifyIdentity
	}
	return in.Mode
}

// ConfigMapKeyRef selects a key of a ConfigMap in the same namespace
type ConfigMapKeyRef struct {
	// ConfigMapName is the name of the ConfigMap
	// +kubebuilder:validation:MinLength=1
	ConfigMapName string `json:"configMapName"`
	// Key is the ConfigMap key
	// +kubebuilder:validation:MinLength=1
	Key string `json:"key"`
}
