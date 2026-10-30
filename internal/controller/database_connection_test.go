package controller

import (
	"github.com/go-sql-driver/mysql"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	stroomv1 "github.com/gradata-systems/stroom-k8s-operator/api/v1"
)

var _ = Describe("Database connections", func() {

	Context("databaseConfig()", func() {
		dbInfo := &DatabaseConnectionInfo{
			ServerAddress: stroomv1.ServerAddress{Host: "mysql.example.com", Port: 3306},
			UserName:      "stroomuser",
		}

		It("should connect over TCP with TLS, if the server supports it", func() {
			config, err := databaseConfig(dbInfo, "password", "stroom", nil)
			Expect(err).ToNot(HaveOccurred())
			Expect(config.Net).To(Equal("tcp"))
			Expect(config.Addr).To(Equal("mysql.example.com:3306"))
			Expect(config.DBName).To(Equal("stroom"))
			Expect(config.User).To(Equal("stroomuser"))
			Expect(config.TLSConfig).To(Equal("preferred"))
			Expect(config.TLS).To(BeNil())
		})

		It("should keep passwords containing characters with a meaning in data source names", func() {
			for _, password := range []string{"p@ss/word", "a:b@tcp(c)/d", "?tls=false"} {
				config, err := databaseConfig(dbInfo, password, "stroom", nil)
				Expect(err).ToNot(HaveOccurred(), password)
				Expect(config.Passwd).To(Equal(password))
				parsed, err := mysql.ParseDSN(config.FormatDSN())
				Expect(err).ToNot(HaveOccurred(), password)
				Expect(parsed.Passwd).To(Equal(password))
				Expect(parsed.TLSConfig).To(Equal("preferred"))
			}
		})
	})
})
