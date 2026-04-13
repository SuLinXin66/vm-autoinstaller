package winsvc

// ExecRequest is sent from a client to the service over the Named Pipe.
//
//   type "exec": run a script file  (Script + Args + Env)
//   type "cmd":  run an inline PowerShell command string (Command)
type ExecRequest struct {
	Type    string            `json:"type"`              // "exec" | "cmd"
	Script  string            `json:"script,omitempty"`  // script name (exec)
	Command string            `json:"command,omitempty"` // PowerShell command string (cmd)
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

// StreamMsg is sent from the service back to a client, one JSON line at a time.
type StreamMsg struct {
	Type string `json:"type"`           // "out" | "err" | "done"
	Data string `json:"data,omitempty"` // line content for out/err
	Code int    `json:"code"`           // exit code for done (always included)
}
