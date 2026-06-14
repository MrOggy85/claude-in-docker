package naming

import (
	"strings"
	"testing"
)

func TestSafeName(t *testing.T) {
	tests := []struct {
		dir  string
		want string
	}{
		{"/home/user/my-project", "my-project"},
		{"/home/user/My_Project", "my-project"},
		{"/home/user/My Project!", "my-project"},
		{"/home/user/---foo---", "foo"},
		{"/home/user/UPPERCASE", "uppercase"},
		{"/home/user/123", "123"},
		{"/home/user/a.b.c", "a-b-c"},
		{"/home/user/foo--bar", "foo-bar"},   // run collapse
		{"/home/user/foo---bar", "foo-bar"},  // run collapse
		{"/home/user/---", ""},              // entirely non-alnum → empty
		{"/home/user/hello_world", "hello-world"},
	}
	for _, tt := range tests {
		got := SafeName(tt.dir)
		if got != tt.want {
			t.Errorf("SafeName(%q) = %q, want %q", tt.dir, got, tt.want)
		}
	}
}

func TestPathHash(t *testing.T) {
	h := PathHash("/home/user/project")
	if len(h) != 10 {
		t.Errorf("PathHash length = %d, want 10", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			t.Errorf("PathHash contains non-hex char %q", string(c))
		}
	}
	// Determinism
	if PathHash("/home/user/project") != PathHash("/home/user/project") {
		t.Error("PathHash not deterministic")
	}
	// Distinct inputs → distinct hashes
	if PathHash("/home/user/project") == PathHash("/home/user/other") {
		t.Error("Different paths produce same PathHash")
	}
}

// TestPathHashPinned pins the exact hash of the empty string (sha256("") is
// universally known) to detect any algorithm changes that would break existing
// session volumes.
func TestPathHashPinned(t *testing.T) {
	// sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
	// first 10 hex chars = "e3b0c44298"
	got := PathHash("")
	const want = "e3b0c44298"
	if got != want {
		t.Errorf("PathHash(\"\") = %q, want %q — changing this means existing volumes can't be found", got, want)
	}
}

func TestVolumeName(t *testing.T) {
	// Structure test
	got := VolumeName("myproject", "/home/user/myproject")
	if !strings.HasPrefix(got, "claude-myproject-") {
		t.Errorf("VolumeName = %q, expected prefix claude-myproject-", got)
	}
	hash := PathHash("/home/user/myproject")
	want := "claude-myproject-" + hash
	if got != want {
		t.Errorf("VolumeName = %q, want %q", got, want)
	}
}

// TestVolumeNamePinned pins a known path → volume name mapping.
// This test must never be changed silently — doing so would orphan all existing
// session volumes for users of this path.
func TestVolumeNamePinned(t *testing.T) {
	// PathHash("") = "e3b0c44298" (verified in TestPathHashPinned)
	got := VolumeName("myproject", "")
	const want = "claude-myproject-e3b0c44298"
	if got != want {
		t.Errorf("VolumeName pinned = %q, want %q — this breaks existing session volumes", got, want)
	}
}

func TestVolumeNameFallback(t *testing.T) {
	got := VolumeName("", "/some/path")
	if !strings.HasPrefix(got, "claude-repo-") {
		t.Errorf("VolumeName with empty safeName = %q, expected prefix claude-repo-", got)
	}
}

func TestContainerName(t *testing.T) {
	got := ContainerName("myproject")
	if !strings.HasPrefix(got, "claude-myproject-") {
		t.Errorf("ContainerName = %q, expected prefix claude-myproject-", got)
	}
	suffix := strings.TrimPrefix(got, "claude-myproject-")
	if len(suffix) != 8 {
		t.Errorf("ContainerName suffix length = %d, want 8 hex chars", len(suffix))
	}
	for _, c := range suffix {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			t.Errorf("ContainerName suffix contains non-hex char %q", string(c))
		}
	}
	// Names should differ across calls (probabilistic; chance of collision is 1/2^32)
	if ContainerName("myproject") == ContainerName("myproject") {
		// Allow one false positive in testing but log it
		t.Log("ContainerName returned same value twice (very unlikely, may be flaky)")
	}
}

func TestContainerNameFallback(t *testing.T) {
	got := ContainerName("")
	if !strings.HasPrefix(got, "claude-repo-") {
		t.Errorf("ContainerName with empty safeName = %q, expected prefix claude-repo-", got)
	}
}
