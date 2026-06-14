package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MrOggy85/claude-in-docker/internal/docker"
)

// TestRun_orchestration drives the whole run() flow against a FakeRunner — no
// real Docker — and pins the wiring that unit tests of the individual pieces
// cannot reach: the session's exit code is propagated, usage sync runs after
// the session even when it exits non-zero, and the final `docker run` argv is
// assembled from the resolved config (so a regression that reorders the steps —
// e.g. moving EnsureCredentials after the run — is caught here).
func TestRun_orchestration(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_USAGE_DIR", t.TempDir())
	t.Setenv("CLAUDE_AUTO_USAGE", "true")
	t.Setenv("CLAUDE_VOLUME", "claude-test-vol")
	t.Setenv("CLAUDE_CONTAINER_NAME", "claude-test-ctr")
	t.Setenv("CLAUDE_MOUNTS", "")
	t.Setenv("CLAUDE_PORTS", "")
	// Skip in-repo path volumes so the recorded docker calls are just the image
	// build, the session run, and usage sync — a deterministic sequence.
	t.Setenv("SKIP_CLAUDE_VOLUME_PATHS", "1")

	// run() seeds SCRIPT_DIR/.credentials.json via EnsureCredentials; don't leak it.
	cleanupCredFile(t)

	// The session run is the only interactive call; have it exit 42 so we can
	// prove the code propagates and that sync still runs afterwards. CodeFor
	// keys off the command, so the assertion survives added/reordered calls.
	runner := &docker.FakeRunner{
		CodeFor: func(name string, args []string, interactive bool) int {
			if interactive {
				return 42
			}
			return 0
		},
	}

	code := run([]string{"--help"}, runner)

	if code != 42 {
		t.Fatalf("run() = %d, want 42 (session exit code must propagate)", code)
	}

	// The final `docker run` argv shape: docker run ... <image> claude <args...>
	session := sessionRun(t, runner)
	if len(session.Args) == 0 || session.Args[0] != "run" {
		t.Fatalf("session argv = %v, want it to start with \"run\"", session.Args)
	}
	mustSequence(t, session.Args, "--name", "claude-test-ctr")
	mustSequence(t, session.Args, "--workdir", "/home/dev/repo")
	mustArg(t, session.Args, "claude-code:local") // image
	mustArg(t, session.Args, "claude")            // entrypoint command
	mustArg(t, session.Args, "--help")            // forwarded verbatim
	mustArg(t, session.Args, "claude-test-vol:/home/dev/.claude")
	// EnsureCredentials ran before argv assembly, so the cred mount is present.
	if !hasArgWithSuffix(session.Args, "/.claude/.credentials.json") {
		t.Errorf("credentials mount missing from session argv — EnsureCredentials may have run too late: %v", session.Args)
	}

	// Usage sync must run AFTER the session, regardless of the non-zero exit.
	sessionIdx := indexOfCommand(runner.Commands, func(c docker.FakeCall) bool {
		return c.Interactive
	})
	syncIdx := indexOfCommand(runner.Commands, func(c docker.FakeCall) bool {
		return hasArg(c.Args, "claude-test-vol:/data:ro")
	})
	if syncIdx < 0 {
		t.Fatalf("usage sync was not attempted (no read of claude-test-vol:/data:ro in %d commands)", len(runner.Commands))
	}
	if syncIdx <= sessionIdx {
		t.Errorf("usage sync ran at command %d, want after the session run at %d", syncIdx, sessionIdx)
	}
}

// ---- helpers ----

func sessionRun(t *testing.T, r *docker.FakeRunner) docker.FakeCall {
	t.Helper()
	for _, c := range r.Commands {
		if c.Interactive {
			return c
		}
	}
	t.Fatalf("no interactive session run recorded among %d commands", len(r.Commands))
	return docker.FakeCall{}
}

// cleanupCredFile removes the .credentials.json that run() writes next to the
// test binary, but only if it didn't already exist (so a real file is left alone).
func cleanupCredFile(t *testing.T) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		return
	}
	cred := filepath.Join(filepath.Dir(exe), ".credentials.json")
	if _, err := os.Stat(cred); err == nil {
		return // pre-existing, not ours to remove
	}
	t.Cleanup(func() { _ = os.Remove(cred) })
}

func indexOfCommand(cmds []docker.FakeCall, pred func(docker.FakeCall) bool) int {
	for i, c := range cmds {
		if pred(c) {
			return i
		}
	}
	return -1
}

func hasArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

func hasArgWithSuffix(args []string, suffix string) bool {
	for _, a := range args {
		if strings.HasSuffix(a, suffix) {
			return true
		}
	}
	return false
}

func mustArg(t *testing.T, args []string, want string) {
	t.Helper()
	if !hasArg(args, want) {
		t.Errorf("arg %q not found in %v", want, args)
	}
}

func mustSequence(t *testing.T, args []string, a, b string) {
	t.Helper()
	for i := 0; i+1 < len(args); i++ {
		if args[i] == a && args[i+1] == b {
			return
		}
	}
	t.Errorf("sequence %q %q not found in %v", a, b, args)
}
