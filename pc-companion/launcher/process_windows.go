package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

// Query only: no process is terminated, and access failures are not treated as death.
func inspectProcess(pid int) (processIdentity, error) {
	info := processIdentity{PID: pid}
	h, err := syscall.OpenProcess(0x1000, false, uint32(pid)) // PROCESS_QUERY_LIMITED_INFORMATION
	if err == syscall.Errno(87) {
		return info, nil // ERROR_INVALID_PARAMETER: PID no longer exists
	}
	if err != nil {
		return info, err
	}
	defer syscall.CloseHandle(h)
	kernel := syscall.NewLazyDLL("kernel32.dll")
	var exitCode uint32
	if ok, _, e := kernel.NewProc("GetExitCodeProcess").Call(uintptr(h), uintptr(unsafe.Pointer(&exitCode))); ok == 0 {
		return info, e
	}
	if exitCode != 259 { // STILL_ACTIVE
		return info, nil
	}
	buffer := make([]uint16, 32768)
	size := uint32(len(buffer))
	if ok, _, e := kernel.NewProc("QueryFullProcessImageNameW").Call(uintptr(h), 0,
		uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size))); ok == 0 {
		return info, e
	}
	var created, exited, kernelTime, userTime syscall.Filetime
	if err := syscall.GetProcessTimes(h, &created, &exited, &kernelTime, &userTime); err != nil {
		return info, err
	}
	info.Running = true
	info.Executable = syscall.UTF16ToString(buffer[:size])
	info.Started = fmt.Sprintf("%08x%08x", created.HighDateTime, created.LowDateTime)
	return info, nil
}
