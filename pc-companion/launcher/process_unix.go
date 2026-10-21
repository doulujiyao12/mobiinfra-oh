//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

func inspectProcess(pid int) (processIdentity, error) {
	info := processIdentity{PID: pid}
	if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
		return info, nil
	} else if err != nil {
		return info, err
	}
	if runtime.GOOS == "linux" {
		folder := filepath.Join("/proc", strconv.Itoa(pid))
		stat, err := os.ReadFile(filepath.Join(folder, "stat"))
		if errors.Is(err, os.ErrNotExist) {
			return info, nil
		}
		if err != nil {
			return info, err
		}
		fields := strings.Fields(string(stat)[strings.LastIndex(string(stat), ")")+1:])
		if len(fields) < 20 {
			return info, errors.New("Invalid process stat")
		}
		if fields[0] == "Z" {
			return info, nil
		}
		info.Started = fields[19] // field 22: starttime, measured from boot
		info.Executable, err = os.Readlink(filepath.Join(folder, "exe"))
		if errors.Is(err, os.ErrNotExist) {
			return processIdentity{PID: pid}, nil
		}
		if err != nil {
			return info, err
		}
	} else {
		output, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "lstart=", "-o", "comm=").Output()
		if err != nil {
			return info, err
		}
		fields := strings.Fields(string(output))
		if len(fields) < 6 {
			return info, errors.New("Invalid process identity")
		}
		info.Started = strings.Join(fields[:5], " ")
		info.Executable = strings.TrimSpace(string(output)[strings.Index(string(output), fields[4])+len(fields[4]):])
	}
	info.Running = true
	return info, nil
}
