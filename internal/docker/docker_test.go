package docker

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildImageArgs(t *testing.T) {
	args := BuildImageArgs("claude-code:local", "abc123", "/path/to/scripts")
	want := []string{"build", "--tag", "claude-code:local", "--label", "build.context-hash=abc123", "/path/to/scripts"}
	if len(args) != len(want) {
		t.Fatalf("BuildImageArgs len = %d, want %d\nGot: %v", len(args), len(want), args)
	}
	for i := range want {
		if args[i] != want[i] {
			t.Errorf("BuildImageArgs[%d] = %q, want %q", i, args[i], want[i])
		}
	}
}

func TestBuildRunArgs_basicStructure(t *testing.T) {
	cfg := RunConfig{
		ContainerName:   "claude-test-abc12345",
		UserUID:         "1000:1000",
		HomeInContainer: "/home/dev",
		RepoInContainer: "/home/dev/repo",
		VolumeName:      "claude-test-a1b2c3d4e5",
		ProjectDir:      "/home/user/project",
		Image:           "claude-code:local",
		ClaudeArgs:      []string{"--model", "opus"},
	}
	args := BuildRunArgs(cfg)

	// Check required args are present in order
	mustContainSequence(t, args, "--name", "claude-test-abc12345")
	mustContainSequence(t, args, "--user", "1000:1000")
	mustContainArg(t, args, "--cap-add=NET_ADMIN")
	mustContainSequence(t, args, "--env", "HOME=/home/dev")
	mustContainSequence(t, args, "--env", "COLORTERM=truecolor")
	mustContainSequence(t, args, "--env", "MCP_GH_BEARER")
	mustContainSequence(t, args, "--volume", "/home/user/project:/home/dev/repo")
	mustContainSequence(t, args, "--volume", "claude-test-a1b2c3d4e5:/home/dev/.claude")
	mustContainSequence(t, args, "--workdir", "/home/dev/repo")

	// Image and claude command must come at the end
	imageIdx := indexOfArg(args, "claude-code:local")
	if imageIdx < 0 {
		t.Fatal("image not found in args")
	}
	if args[imageIdx+1] != "claude" {
		t.Errorf("arg after image = %q, want %q", args[imageIdx+1], "claude")
	}
	// Forwarded args follow
	if args[imageIdx+2] != "--model" || args[imageIdx+3] != "opus" {
		t.Errorf("forwarded args not found after 'claude'")
	}
}

func TestBuildRunArgs_noClaudeArgs(t *testing.T) {
	cfg := RunConfig{
		ContainerName:   "c",
		UserUID:         "0:0",
		HomeInContainer: "/home/dev",
		RepoInContainer: "/home/dev/repo",
		VolumeName:      "v",
		ProjectDir:      "/p",
		Image:           "claude-code:local",
	}
	args := BuildRunArgs(cfg)
	last := args[len(args)-1]
	if last != "claude" {
		t.Errorf("last arg = %q, want 'claude'", last)
	}
}

func TestBuildRunArgs_publishArgsOrder(t *testing.T) {
	cfg := RunConfig{
		ContainerName:   "c",
		UserUID:         "1:1",
		HomeInContainer: "/home/dev",
		RepoInContainer: "/home/dev/repo",
		VolumeName:      "v",
		ProjectDir:      "/p",
		Image:           "img",
		PublishArgs:     []string{"8080:8080/tcp", "9090:9090/tcp"},
	}
	args := BuildRunArgs(cfg)

	// Both publish args must appear
	mustContainSequence(t, args, "--publish", "8080:8080/tcp")
	mustContainSequence(t, args, "--publish", "9090:9090/tcp")

	// Publish args must appear before volume mounts
	pubIdx := indexOfArg(args, "--publish")
	volIdx := indexOfArg(args, "--volume")
	if pubIdx < 0 || volIdx < 0 {
		t.Fatal("publish or volume not found")
	}
	if pubIdx > volIdx {
		t.Errorf("--publish (idx %d) should come before --volume (idx %d)", pubIdx, volIdx)
	}
}

func TestBuildRunArgs_volumePathMounts(t *testing.T) {
	cfg := RunConfig{
		ContainerName:   "c",
		UserUID:         "1:1",
		HomeInContainer: "/home/dev",
		RepoInContainer: "/home/dev/repo",
		VolumeName:      "session-vol",
		ProjectDir:      "/p",
		Image:           "img",
		VolumePathMounts: []string{"--volume", "path-vol:/home/dev/repo/node_modules"},
	}
	args := BuildRunArgs(cfg)
	mustContainSequence(t, args, "--volume", "path-vol:/home/dev/repo/node_modules")

	// VolumePathMounts must appear between project mount and session .claude mount
	projIdx := indexOfSequence(args, "--volume", "/p:/home/dev/repo")
	pathIdx := indexOfSequence(args, "--volume", "path-vol:/home/dev/repo/node_modules")
	sessIdx := indexOfSequence(args, "--volume", "session-vol:/home/dev/.claude")
	if projIdx < 0 || pathIdx < 0 || sessIdx < 0 {
		t.Fatalf("missing expected volume args: proj=%d path=%d sess=%d", projIdx, pathIdx, sessIdx)
	}
	if !(projIdx < pathIdx && pathIdx < sessIdx) {
		t.Errorf("volume order wrong: proj=%d path=%d sess=%d", projIdx, pathIdx, sessIdx)
	}
}

func TestConfigMounts_presentAndAbsent(t *testing.T) {
	dir := t.TempDir()
	// Only create settings.json and .credentials.json
	os.WriteFile(filepath.Join(dir, "settings.json"), []byte("{}"), 0644)
	os.WriteFile(filepath.Join(dir, ".credentials.json"), []byte("{}"), 0600)

	var stderr strings.Builder
	mounts := ConfigMounts(dir, "/home/dev", &stderr)

	// settings.json present → should be in mounts (as ro)
	foundSettings := false
	foundCreds := false
	for i := 0; i < len(mounts)-1; i++ {
		if mounts[i] == "--volume" {
			if strings.HasSuffix(mounts[i+1], "settings.json:/home/dev/.claude/settings.json:ro") {
				foundSettings = true
			}
			if strings.HasSuffix(mounts[i+1], ".credentials.json:/home/dev/.claude/.credentials.json") &&
				!strings.HasSuffix(mounts[i+1], ":ro") {
				foundCreds = true
			}
		}
	}
	if !foundSettings {
		t.Errorf("settings.json mount not found; mounts = %v", mounts)
	}
	if !foundCreds {
		t.Errorf("credentials mount not found or is ro; mounts = %v", mounts)
	}

	// claude.json absent → skipped, stderr notice
	if !strings.Contains(stderr.String(), "claude.json") {
		t.Errorf("expected skip notice for claude.json in stderr, got: %s", stderr.String())
	}
}

func TestEnsureCredentials_creates(t *testing.T) {
	dir := t.TempDir()
	if err := EnsureCredentials(dir); err != nil {
		t.Fatalf("EnsureCredentials: %v", err)
	}
	credFile := filepath.Join(dir, ".credentials.json")
	data, err := os.ReadFile(credFile)
	if err != nil {
		t.Fatalf("credentials file not created: %v", err)
	}
	if string(data) != "{}" {
		t.Errorf("credentials content = %q, want {}", string(data))
	}
	fi, _ := os.Stat(credFile)
	if fi.Mode().Perm() != 0600 {
		t.Errorf("credentials file mode = %v, want 0600", fi.Mode().Perm())
	}
}

func TestEnsureCredentials_noopIfExists(t *testing.T) {
	dir := t.TempDir()
	credFile := filepath.Join(dir, ".credentials.json")
	original := []byte(`{"existing":"data"}`)
	os.WriteFile(credFile, original, 0600)

	if err := EnsureCredentials(dir); err != nil {
		t.Fatalf("EnsureCredentials: %v", err)
	}
	data, _ := os.ReadFile(credFile)
	if string(data) != string(original) {
		t.Errorf("credentials file modified: got %q, want %q", string(data), string(original))
	}
}

func TestPreparePathVolumes_skip(t *testing.T) {
	runner := &FakeRunner{}
	cfg := PathVolumeConfig{
		SkipVolumePaths: "1",
	}
	var stderr strings.Builder
	result, err := PreparePathVolumes(context.Background(), cfg, runner, &stderr)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("expected no mounts when skipping, got %v", result)
	}
	if len(runner.Commands) != 0 {
		t.Errorf("expected no docker calls when skipping, got %v", runner.Commands)
	}
	if !strings.Contains(stderr.String(), "SKIP_CLAUDE_VOLUME_PATHS") {
		t.Errorf("expected skip message in stderr, got: %s", stderr.String())
	}
}

func TestPreparePathVolumes_createsNewVolume(t *testing.T) {
	dir := t.TempDir()
	runner := &FakeRunner{
		// find-node-modules-paths.sh returns empty → 0 auto paths
		// But we pass an explicit path; sequence:
		// 1. find-node-modules-paths.sh output (Output call) → ""
		// 2. docker volume inspect → exit 1 (not found)
		// 3. docker volume create → exit 0
		// 4. docker run chown → exit 0
		ExitCodes: []int{0, 1, 0, 0},
		Outputs:   []string{""},
	}
	cfg := PathVolumeConfig{
		ScriptDir:         dir,
		ProjectDir:        dir,
		SafeName:          "testproj",
		RepoInContainer:   "/home/dev/repo",
		Image:             "claude-code:local",
		UID:               1000,
		GID:               1000,
		ClaudeVolumePaths: "extra",
	}
	var stderr strings.Builder
	result, err := PreparePathVolumes(context.Background(), cfg, runner, &stderr)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) < 2 {
		t.Fatalf("expected at least one --volume pair, got %v", result)
	}
	if result[0] != "--volume" {
		t.Errorf("result[0] = %q, want --volume", result[0])
	}
	if !strings.HasPrefix(result[1], "claude-vol-testproj-") {
		t.Errorf("volume name = %q, expected prefix claude-vol-testproj-", result[1])
	}
	if !strings.HasSuffix(result[1], ":/home/dev/repo/extra") {
		t.Errorf("volume target = %q, expected suffix :/home/dev/repo/extra", result[1])
	}
}

// ---- helpers ----

func mustContainArg(t *testing.T, args []string, want string) {
	t.Helper()
	for _, a := range args {
		if a == want {
			return
		}
	}
	t.Errorf("arg %q not found in %v", want, args)
}

func mustContainSequence(t *testing.T, args []string, a, b string) {
	t.Helper()
	if indexOfSequence(args, a, b) < 0 {
		t.Errorf("sequence %q %q not found in %v", a, b, args)
	}
}

func indexOfArg(args []string, want string) int {
	for i, a := range args {
		if a == want {
			return i
		}
	}
	return -1
}

func indexOfSequence(args []string, a, b string) int {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == a && args[i+1] == b {
			return i
		}
	}
	return -1
}
