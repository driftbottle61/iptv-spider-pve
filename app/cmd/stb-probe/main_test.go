package main

import (
	"context"
	"strings"
	"testing"
)

func TestPasswordSSHCommandKeepsSecretOutOfArguments(t *testing.T) {
	c := capture{router: "192.0.2.1", user: "router-user", password: "not-for-command-line", port: 2222}
	cmd := sshExec(context.Background(), c, false, ":put ok")
	joined := strings.Join(cmd.Args, " ")
	if strings.Contains(joined, c.password) {
		t.Fatalf("password leaked into command arguments: %s", joined)
	}
	if !strings.Contains(joined, "sshpass -e ssh") || !strings.Contains(joined, "router-user@192.0.2.1") {
		t.Fatalf("unexpected password SSH command: %s", joined)
	}
	foundPasswordEnv := false
	for _, value := range cmd.Env {
		if value == "SSHPASS="+c.password {
			foundPasswordEnv = true
			break
		}
	}
	if !foundPasswordEnv {
		t.Fatal("SSHPASS environment variable was not set")
	}
}

func TestKeySCPCommandUsesIdentityFile(t *testing.T) {
	c := capture{router: "192.0.2.1", user: "router-user", key: "/tmp/router-key", port: 2222}
	cmd := sshExec(context.Background(), c, true, "router-user@192.0.2.1:capture.pcap", "/tmp/capture.pcap")
	joined := strings.Join(cmd.Args, " ")
	if !strings.Contains(joined, "scp -i /tmp/router-key -P 2222") {
		t.Fatalf("unexpected key SCP command: %s", joined)
	}
}
