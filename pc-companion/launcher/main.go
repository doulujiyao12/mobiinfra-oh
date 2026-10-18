package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--internal-certificates" {
		if len(os.Args) != 4 {
			fatal("Invalid certificate arguments")
		}
		var ips []string
		if err := json.Unmarshal([]byte(os.Args[3]), &ips); err != nil {
			fatal("Invalid IP address list")
		}
		value, err := ensureCertificates(os.Args[2], ips)
		if err != nil {
			fatal(err.Error())
		}
		json.NewEncoder(os.Stdout).Encode(value)
		return
	}
	executable, err := os.Executable()
	if err != nil {
		fatal(err.Error())
	}
	resolved, err := filepath.EvalSymlinks(executable)
	if err == nil {
		executable = resolved
	}
	base := filepath.Dir(filepath.Dir(executable))
	if override := os.Getenv("CLAWMATE_CODEX_RESOURCES"); override != "" {
		base = override
	}
	extension := ""
	if runtime.GOOS == "windows" {
		extension = ".exe"
	}
	node := filepath.Join(base, "runtime", "node"+extension)
	entry := filepath.Join(base, "host", "cli.mjs")
	for _, filename := range []string{node, entry} {
		if _, err := os.Stat(filename); err != nil {
			fatal("安装文件不完整，请重新安装 ClawMate Codex。")
		}
	}
	command := exec.Command(node, append([]string{entry}, os.Args[1:]...)...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	for _, value := range os.Environ() {
		key := strings.SplitN(value, "=", 2)[0]
		if key != "NODE_OPTIONS" && key != "NODE_PATH" && key != "CLAWMATE_CODEX_RESOURCES" {
			command.Env = append(command.Env, value)
		}
	}
	command.Env = append(command.Env, "CLAWMATE_CODEX_RESOURCES="+base)
	if err := command.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			os.Exit(exit.ExitCode())
		}
		fatal(err.Error())
	}
}

func fatal(message string) { fmt.Fprintln(os.Stderr, message); os.Exit(1) }
