package controller

import (
	"context"
	"database/sql"
	"fmt"
	"net"
	"strconv"

	"github.com/go-sql-driver/mysql"
	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

func GetDatabaseConnectionInfo(client client.Client, ctx context.Context, dbRef *stroomv1.DatabaseServerRef, ownerNamespace string, dbConnectionInfo *DatabaseConnectionInfo) error {
	logger := log.FromContext(ctx)

	if dbRef.ServerRef == (stroomv1.ResourceRef{}) {
		// This is an external database connection
		dbConnectionInfo.DatabaseServer = nil
		dbConnectionInfo.Host = dbRef.ServerAddress.Host
		dbConnectionInfo.Port = dbRef.ServerAddress.Port
		dbConnectionInfo.SecretName = dbRef.ServerAddress.SecretName
		dbConnectionInfo.Tls = dbRef.ServerAddress.Tls
		dbConnectionInfo.UserName = dbRef.UserName
	} else {
		// If the ServerRef namespace is empty, try to find the DatabaseServer in the same namespace as the owner
		// (e.g. StroomCluster)
		dbReference := &dbRef.ServerRef
		if dbReference.Namespace == "" {
			dbReference.Namespace = ownerNamespace
		}

		// Get or create an operator-managed database instance
		dbServer := stroomv1.DatabaseServer{}
		if err := client.Get(ctx, dbReference.NamespacedName(), &dbServer); err != nil {
			if errors.IsNotFound(err) {
				logger.Error(err, "DatabaseServer was not found", "Reference", dbReference)
			} else {
				logger.Error(err, "Error accessing DatabaseServer", "Reference", dbReference)
			}
			return err
		} else {
			dbConnectionInfo.DatabaseServer = &dbServer
			dbConnectionInfo.Host = dbServer.GetServiceFqdn()
			dbConnectionInfo.Port = DatabasePort
			dbConnectionInfo.SecretName = dbServer.GetSecretName()
			dbConnectionInfo.Tls = nil
			dbConnectionInfo.UserName = dbRef.UserName
		}
	}

	return nil
}

func OpenDatabase(client client.Reader, ctx context.Context, dbInfo *DatabaseConnectionInfo, secretNamespace string, databaseName string) (*sql.DB, error) {
	logger := log.FromContext(ctx)

	// Get password from secret
	dbSecret := v1.Secret{}
	if err := client.Get(ctx, types.NamespacedName{Namespace: secretNamespace, Name: dbInfo.SecretName}, &dbSecret); err != nil {
		logger.Error(err, fmt.Sprintf("Could not retrieve database password from Secret '%v'", dbInfo.SecretName))
		return nil, err
	}

	var caCertificates []byte
	if dbInfo.Tls != nil && dbInfo.Tls.CaCertificates != nil {
		ref := dbInfo.Tls.CaCertificates
		configMap := v1.ConfigMap{}
		if err := client.Get(ctx, types.NamespacedName{Namespace: secretNamespace, Name: ref.ConfigMapName}, &configMap); err != nil {
			logger.Error(err, fmt.Sprintf("Could not retrieve the database CA certificates from ConfigMap '%v'", ref.ConfigMapName))
			return nil, err
		}
		caCertificates = []byte(configMap.Data[ref.Key])
	}

	password := string(dbSecret.Data[dbInfo.UserName])
	config, err := databaseConfig(dbInfo, password, databaseName, caCertificates)
	if err != nil {
		logger.Error(err, "Could not configure the database connection", "HostName", dbInfo.Host, "Database", databaseName)
		return nil, err
	}
	connector, err := mysql.NewConnector(config)
	if err != nil {
		logger.Error(err, "Could not connect to database", "HostName", dbInfo.Host, "Database", databaseName, "User", dbInfo.UserName)
		return nil, err
	}
	return sql.OpenDB(connector), nil
}

func CloseDatabase(database *sql.DB) {
	if err := database.Close(); err != nil {
		// Handle silently
	}
}

// databaseConfig returns the MySQL connection settings for a database. Unless the connection's TLS settings say
// otherwise, TLS is used if the server supports it, so the password isn't sent in clear text, and the server's
// certificate isn't verified, as MySQL servers generate their own by default.
func databaseConfig(dbInfo *DatabaseConnectionInfo, password string, databaseName string, caCertificates []byte) (*mysql.Config, error) {
	config := mysql.NewConfig()
	config.User = dbInfo.UserName
	config.Passwd = password
	config.Net = "tcp"
	config.Addr = net.JoinHostPort(dbInfo.Host, strconv.Itoa(int(dbInfo.Port)))
	config.DBName = databaseName
	if err := configureDatabaseTls(config, dbInfo.Host, dbInfo.Tls, caCertificates); err != nil {
		return nil, err
	}
	return config, nil
}
