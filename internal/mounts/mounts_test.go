package mounts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stderrDiscard discards all writes (used when we don't care about stderr output).
type stderrDiscard struct{}

func (stderrDiscard) Write(p []byte) (int, error) { return len(p), nil }

func TestParseMounts_empty(t *testing.T) {
	result := ParseMounts("", "/home/user", "/project", "/home/dev", "/home/dev/repo", stderrDiscard{})
	if len(result) != 0 {
		t.Errorf("ParseMounts(\"\") = %v, want empty", result)
	}
}

func TestParseMounts_roDefault(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "mydir")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}

	result := ParseMounts(sub, "/home/user", "/project", "/home/dev", "/home/dev/repo", stderrDiscard{})

	base := filepath.Base(sub)
	want := "/home/dev/" + base + ":ro"
	if len(result) != 2 || result[0] != "--volume" || !strings.HasSuffix(result[1], want) {
		t.Errorf("ParseMounts ro default = %v, want --volume ...%s", result, want)
	}
}

func TestParseMounts_rwSuffix(t *testing.T) {
	dir := t.TempDir()

	result := ParseMounts(dir+":rw", "/home/user", "/project", "/home/dev", "/home/dev/repo", stderrDiscard{})

	if len(result) != 2 || result[0] != "--volume" {
		t.Fatalf("ParseMounts :rw = %v, want 2 elements", result)
	}
	if !strings.HasSuffix(result[1], ":rw") {
		t.Errorf("expected :rw suffix, got %q", result[1])
	}
}

func TestParseMounts_roSuffix(t *testing.T) {
	dir := t.TempDir()

	result := ParseMounts(dir+":ro", "/home/user", "/project", "/home/dev", "/home/dev/repo", stderrDiscard{})

	if len(result) != 2 || result[0] != "--volume" {
		t.Fatalf("ParseMounts :ro = %v, want 2 elements", result)
	}
	if !strings.HasSuffix(result[1], ":ro") {
		t.Errorf("expected :ro suffix, got %q", result[1])
	}
}

func TestParseMounts_tildeExpansion(t *testing.T) {
	homeDir := t.TempDir()
	subDir := filepath.Join(homeDir, "mymount")
	if err := os.Mkdir(subDir, 0755); err != nil {
		t.Fatal(err)
	}

	result := ParseMounts("~/mymount", homeDir, "/project", "/home/dev", "/home/dev/repo", stderrDiscard{})

	if len(result) != 2 {
		t.Fatalf("tilde expansion result = %v", result)
	}
	if !strings.Contains(result[1], "mymount") {
		t.Errorf("expanded path doesn't contain mymount: %q", result[1])
	}
}

func TestParseMounts_tildeBareExpansion(t *testing.T) {
	homeDir := t.TempDir()

	result := ParseMounts("~", homeDir, "/project", "/home/dev", "/home/dev/repo", stderrDiscard{})

	if len(result) != 2 {
		t.Fatalf("bare ~ expansion result = %v", result)
	}
}

func TestParseMounts_relativePathExpansion(t *testing.T) {
	projectDir := t.TempDir()
	subDir := filepath.Join(projectDir, "extra")
	if err := os.Mkdir(subDir, 0755); err != nil {
		t.Fatal(err)
	}

	result := ParseMounts("extra", "/home/user", projectDir, "/home/dev", "/home/dev/repo", stderrDiscard{})

	if len(result) != 2 {
		t.Fatalf("relative path expansion result = %v", result)
	}
}

func TestParseMounts_notFoundSkipped(t *testing.T) {
	var stderr strings.Builder
	result := ParseMounts("/nonexistent/path", "/home/user", "/project", "/home/dev", "/home/dev/repo", &stderr)

	if len(result) != 0 {
		t.Errorf("nonexistent path should be skipped, got %v", result)
	}
	if !strings.Contains(stderr.String(), "not found on host") {
		t.Errorf("expected 'not found on host' in stderr, got %q", stderr.String())
	}
}

func TestParseMounts_duplicateTargetSkipped(t *testing.T) {
	dir1 := t.TempDir()
	// Create two directories with the same basename to trigger target collision
	dir2Parent := t.TempDir()
	sameBase := filepath.Join(dir2Parent, filepath.Base(dir1))
	if err := os.Mkdir(sameBase, 0755); err != nil {
		t.Fatal(err)
	}

	var stderr strings.Builder
	result := ParseMounts(dir1+","+sameBase, "/home/user", "/project", "/home/dev", "/home/dev/repo", &stderr)

	// First one accepted, second skipped
	if len(result) != 2 { // only one --volume pair
		t.Errorf("expected 1 mount (2 args), got %d: %v", len(result), result)
	}
	if !strings.Contains(stderr.String(), "already in use") {
		t.Errorf("expected 'already in use' in stderr, got %q", stderr.String())
	}
}

func TestParseMounts_whitespace(t *testing.T) {
	dir := t.TempDir()
	result := ParseMounts("  "+dir+"  ", "/home/user", "/project", "/home/dev", "/home/dev/repo", stderrDiscard{})
	if len(result) != 2 {
		t.Errorf("whitespace-padded entry should parse, got %v", result)
	}
}

// ---- ParsePorts tests ----

func TestParsePorts_empty(t *testing.T) {
	result := ParsePorts("", stderrDiscard{})
	if len(result) != 0 {
		t.Errorf("ParsePorts(\"\") = %v, want empty", result)
	}
}

func TestParsePorts_singlePort(t *testing.T) {
	result := ParsePorts("8080", stderrDiscard{})
	if len(result) != 1 {
		t.Fatalf("expected 1 result, got %d: %v", len(result), result)
	}
	if result[0].PublishArg != "8080:8080/tcp" {
		t.Errorf("PublishArg = %q, want 8080:8080/tcp", result[0].PublishArg)
	}
	if result[0].ContainerPort != "8080/tcp" {
		t.Errorf("ContainerPort = %q, want 8080/tcp", result[0].ContainerPort)
	}
}

func TestParsePorts_hostColonContainer(t *testing.T) {
	result := ParsePorts("3000:3001", stderrDiscard{})
	if len(result) != 1 {
		t.Fatalf("expected 1 result, got %v", result)
	}
	if result[0].PublishArg != "3000:3001/tcp" {
		t.Errorf("PublishArg = %q, want 3000:3001/tcp", result[0].PublishArg)
	}
	if result[0].ContainerPort != "3001/tcp" {
		t.Errorf("ContainerPort = %q, want 3001/tcp", result[0].ContainerPort)
	}
}

func TestParsePorts_ipHostContainer(t *testing.T) {
	result := ParsePorts("127.0.0.1:8080:8080", stderrDiscard{})
	if len(result) != 1 {
		t.Fatalf("expected 1 result, got %v", result)
	}
	if result[0].PublishArg != "127.0.0.1:8080:8080/tcp" {
		t.Errorf("PublishArg = %q, want 127.0.0.1:8080:8080/tcp", result[0].PublishArg)
	}
	if result[0].ContainerPort != "8080/tcp" {
		t.Errorf("ContainerPort = %q, want 8080/tcp", result[0].ContainerPort)
	}
}

func TestParsePorts_udpProtocol(t *testing.T) {
	result := ParsePorts("9000/udp", stderrDiscard{})
	if len(result) != 1 {
		t.Fatalf("expected 1 result, got %v", result)
	}
	if result[0].PublishArg != "9000:9000/udp" {
		t.Errorf("PublishArg = %q, want 9000:9000/udp", result[0].PublishArg)
	}
	if result[0].ContainerPort != "9000/udp" {
		t.Errorf("ContainerPort = %q, want 9000/udp", result[0].ContainerPort)
	}
}

func TestParsePorts_tcpExplicit(t *testing.T) {
	result := ParsePorts("8080/tcp", stderrDiscard{})
	if len(result) != 1 {
		t.Fatalf("expected 1 result, got %v", result)
	}
	if result[0].PublishArg != "8080:8080/tcp" {
		t.Errorf("PublishArg = %q, want 8080:8080/tcp", result[0].PublishArg)
	}
}

func TestParsePorts_multiple(t *testing.T) {
	result := ParsePorts("8080,9090", stderrDiscard{})
	if len(result) != 2 {
		t.Errorf("expected 2 results, got %d: %v", len(result), result)
	}
}

func TestParsePorts_invalidPort(t *testing.T) {
	var stderr strings.Builder
	result := ParsePorts("0", &stderr)
	if len(result) != 0 {
		t.Errorf("port 0 should be invalid, got %v", result)
	}
	if !strings.Contains(stderr.String(), "not a valid") {
		t.Errorf("expected 'not a valid' in stderr, got %q", stderr.String())
	}
}

func TestParsePorts_portTooHigh(t *testing.T) {
	var stderr strings.Builder
	result := ParsePorts("65536", &stderr)
	if len(result) != 0 {
		t.Errorf("port 65536 should be invalid, got %v", result)
	}
}

func TestParsePorts_unknownProtocol(t *testing.T) {
	var stderr strings.Builder
	result := ParsePorts("8080/sctp", &stderr)
	if len(result) != 0 {
		t.Errorf("unknown protocol should be skipped, got %v", result)
	}
	if !strings.Contains(stderr.String(), "unknown protocol") {
		t.Errorf("expected 'unknown protocol' in stderr, got %q", stderr.String())
	}
}

func TestParsePorts_tooManyColons(t *testing.T) {
	var stderr strings.Builder
	result := ParsePorts("1:2:3:4", &stderr)
	if len(result) != 0 {
		t.Errorf("too many colons should be skipped, got %v", result)
	}
}

func TestParsePorts_whitespace(t *testing.T) {
	result := ParsePorts("  8080  ", stderrDiscard{})
	if len(result) != 1 {
		t.Errorf("whitespace-padded port should parse, got %v", result)
	}
}

func TestParseAutoUsage(t *testing.T) {
	tests := []struct {
		val  string
		want bool
	}{
		{"", true},
		{"1", true},
		{"yes", true},
		{"on", true},
		{"true", true},
		{"TRUE", true},
		{"0", false},
		{"false", false},
		{"False", false},
		{"FALSE", false},
		{"no", false},
		{"NO", false},
		{"off", false},
		{"OFF", false},
	}
	for _, tt := range tests {
		got := ParseAutoUsage(tt.val)
		if got != tt.want {
			t.Errorf("ParseAutoUsage(%q) = %v, want %v", tt.val, got, tt.want)
		}
	}
}
