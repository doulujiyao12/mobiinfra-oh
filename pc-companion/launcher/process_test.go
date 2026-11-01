package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCurrentProcessIdentity(t *testing.T) {
	first, err := inspectProcess(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	second, err := inspectProcess(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	executable, _ := os.Executable()
	if !first.Running || first.Started == "" || first.Started != second.Started ||
		filepath.Base(first.Executable) != filepath.Base(executable) {
		t.Fatalf("Invalid identity: %+v", first)
	}
}

func TestAbsentProcessIdentity(t *testing.T) {
	info, err := inspectProcess(2147483647)
	if err != nil {
		t.Fatal(err)
	}
	if info.Running {
		t.Fatal("An absent process was reported as running")
	}
}
