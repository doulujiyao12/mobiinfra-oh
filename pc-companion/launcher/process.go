package main

type processIdentity struct {
	PID        int    `json:"pid"`
	Running    bool   `json:"running"`
	Executable string `json:"executable,omitempty"`
	Started    string `json:"started,omitempty"`
}
