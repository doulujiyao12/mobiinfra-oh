package main

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"testing"
	"time"
)

func TestPrivateCAAndHostCertificate(t *testing.T) {
	dir := t.TempDir()
	value, err := ensureCertificates(dir, []string{"192.168.1.20"})
	if err != nil {
		t.Fatal(err)
	}
	if len(value.CACertificate) > 2048 {
		t.Fatal("CA does not fit HarmonyOS integrity-protected label")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(value.CACertificate)) {
		t.Fatal("bad root")
	}
	data, _ := os.ReadFile(value.Cert)
	block, _ := pem.Decode(data)
	leaf, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "192.168.1.20"}); err != nil {
		t.Fatal(err)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "192.168.1.99"}); err == nil {
		t.Fatal("wrong IP accepted")
	}
	if !leaf.NotAfter.Before(time.Now().AddDate(0, 0, 91)) {
		t.Fatal("leaf lifetime too long")
	}
	second, err := ensureCertificates(dir, []string{"192.168.1.20"})
	if err != nil {
		t.Fatal(err)
	}
	if value.Fingerprint != second.Fingerprint {
		t.Fatal("root changed on restart")
	}
	third, err := ensureCertificates(dir, []string{"192.168.1.21"})
	if err != nil {
		t.Fatal(err)
	}
	if value.Fingerprint != third.Fingerprint {
		t.Fatal("IP update changed pairing identity")
	}
	data, _ = os.ReadFile(third.Cert)
	block, _ = pem.Decode(data)
	leaf, _ = x509.ParseCertificate(block.Bytes)
	if err = leaf.VerifyHostname("192.168.1.21"); err != nil {
		t.Fatal(err)
	}
}

func TestMissingRootKeyFailsClosed(t *testing.T) {
	dir := t.TempDir()
	_, err := ensureCertificates(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	os.Remove(dir + "/pairing-ca-key.pem")
	if _, err = ensureCertificates(dir, nil); err == nil {
		t.Fatal("missing root key silently replaced")
	}
}
