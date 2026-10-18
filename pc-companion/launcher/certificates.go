package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type certificateResult struct {
	Cert          string `json:"cert"`
	Key           string `json:"key"`
	CACertificate string `json:"caCertificate"`
	Fingerprint   string `json:"fingerprint"`
}

func privateWrite(filename string, data []byte) error {
	if err := os.WriteFile(filename+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(filename+".tmp", filename)
}
func parseCertificate(data []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("Certificate file is invalid")
	}
	return x509.ParseCertificate(block.Bytes)
}
func randomSerial() *big.Int {
	value, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		panic(err)
	}
	return value
}
func ensureCertificates(directory string, addresses []string) (certificateResult, error) {
	var result certificateResult
	if !filepath.IsAbs(directory) {
		return result, errors.New("Certificate directory must be absolute")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return result, err
	}
	rootFile := filepath.Join(directory, "pairing-ca.pem")
	rootKeyFile := filepath.Join(directory, "pairing-ca-key.pem")
	result.Cert = filepath.Join(directory, "server-cert.pem")
	result.Key = filepath.Join(directory, "server-key.pem")
	rootPEM, rootError := os.ReadFile(rootFile)
	keyPEM, keyError := os.ReadFile(rootKeyFile)
	var root *x509.Certificate
	var rootKey crypto.Signer
	created := false
	if os.IsNotExist(rootError) && os.IsNotExist(keyError) {
		created = true
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return result, err
		}
		rootKey = key
		root = &x509.Certificate{SerialNumber: randomSerial(), Subject: pkix.Name{CommonName: "ClawMate pairing CA"},
			NotBefore: time.Now().Add(-5 * time.Minute), NotAfter: time.Now().AddDate(3, 0, 0), IsCA: true,
			BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true,
			KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign}
		der, err := x509.CreateCertificate(rand.Reader, root, root, key.Public(), key)
		if err != nil {
			return result, err
		}
		rootPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		private, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return result, err
		}
		if err = privateWrite(rootFile, rootPEM); err != nil {
			return result, err
		}
		if err = privateWrite(rootKeyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})); err != nil {
			return result, err
		}
		root, err = x509.ParseCertificate(der)
		if err != nil {
			return result, err
		}
	} else {
		if rootError != nil || keyError != nil {
			return result, errors.New("配对证书或私钥缺失，请保留数据并重新配置配对证书。")
		}
		var err error
		root, err = parseCertificate(rootPEM)
		if err != nil {
			return result, err
		}
		block, _ := pem.Decode(keyPEM)
		if block == nil {
			return result, errors.New("Invalid CA key")
		}
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return result, err
		}
		var ok bool
		rootKey, ok = parsed.(crypto.Signer)
		if !ok {
			return result, errors.New("Invalid signing key")
		}
		if err = root.CheckSignatureFrom(root); err != nil {
			return result, err
		}
		certPublic, _ := x509.MarshalPKIXPublicKey(root.PublicKey)
		privatePublic, _ := x509.MarshalPKIXPublicKey(rootKey.Public())
		if string(certPublic) != string(privatePublic) {
			return result, errors.New("CA key does not match certificate")
		}
		if root.NotAfter.Before(time.Now().AddDate(0, 0, 1)) {
			return result, errors.New("配对证书即将到期，请重置电脑配对并重新连接手机。")
		}
	}
	ips := []net.IP{net.ParseIP("127.0.0.1")}
	for _, value := range addresses {
		ip := net.ParseIP(value)
		if ip == nil {
			return result, errors.New("Invalid certificate IP")
		}
		ips = append(ips, ip)
	}
	renew := created
	leafPEM, err := os.ReadFile(result.Cert)
	if err != nil {
		renew = true
	} else {
		leaf, e := parseCertificate(leafPEM)
		if e != nil || leaf.NotAfter.Before(time.Now().AddDate(0, 0, 14)) || leaf.CheckSignatureFrom(root) != nil {
			renew = true
		} else {
			for _, ip := range ips {
				if leaf.VerifyHostname(ip.String()) != nil {
					renew = true
				}
			}
		}
	}
	if _, err = os.Stat(result.Key); err != nil {
		renew = true
	}
	if renew {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return result, err
		}
		notAfter := time.Now().AddDate(0, 0, 90)
		if notAfter.After(root.NotAfter) {
			notAfter = root.NotAfter
		}
		leaf := &x509.Certificate{SerialNumber: randomSerial(), Subject: pkix.Name{CommonName: "ClawMate Codex"},
			NotBefore: time.Now().Add(-5 * time.Minute), NotAfter: notAfter, BasicConstraintsValid: true,
			KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			DNSNames: []string{"localhost"}, IPAddresses: ips}
		der, err := x509.CreateCertificate(rand.Reader, leaf, root, key.Public(), rootKey)
		if err != nil {
			return result, err
		}
		private, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return result, err
		}
		if err = privateWrite(result.Cert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); err != nil {
			return result, err
		}
		if err = privateWrite(result.Key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})); err != nil {
			return result, err
		}
	}
	result.CACertificate = string(rootPEM)
	fingerprint := sha256.Sum256(root.Raw)
	encoded := strings.ToUpper(hex.EncodeToString(fingerprint[:]))
	parts := []string{}
	for index := 0; index < len(encoded); index += 2 {
		parts = append(parts, encoded[index:index+2])
	}
	result.Fingerprint = strings.Join(parts, ":")
	return result, nil
}
