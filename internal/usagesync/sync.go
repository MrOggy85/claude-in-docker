// Package usagesync copies JSONL usage records from a Docker session volume
// into a host archive directory, keeping only the fields ccusage reads to
// compute cost. The transform is an allowlist (not a denylist): conversation
// text, tool I/O, thinking, and attachments are never copied.
//
// This is the single source of the transform — run.sh (per-session) and
// usage.sh (all volumes) both delegate here.
package usagesync

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/MrOggy85/claude-in-docker/internal/docker"
)

// SyncVolume copies the usage records from a session volume into archiveDir.
//
// It runs a throwaway Docker container to read the JSONL files from the volume
// (which is inaccessible directly from the host), filters each record through
// a Go-native allowlist transform, and writes the results to
// <archiveDir>/projects/<proj>/<filename>.
//
// Parameters:
//   - ctx: context for the docker invocations
//   - runner: command executor (docker.RealRunner in production, a fake in tests)
//   - image: Docker image that will be used as the reader container
//   - volume: Docker volume name (e.g. "claude-myproject-abc123def0")
//   - proj: human-readable project name used as the destination subdirectory
//   - archiveDir: host path for the shared usage archive
func SyncVolume(ctx context.Context, runner docker.Runner, image, volume, proj, archiveDir string) error {
	// Verify the image exists before trying to run it.
	if _, code, err := runner.Output(ctx, "docker", []string{"image", "inspect", image}); err != nil || code != 0 {
		return fmt.Errorf("image %s not found — run ./run.sh (or ./claude) once to build it", image)
	}

	destDir := filepath.Join(archiveDir, "projects", proj)
	if err := os.MkdirAll(destDir, 0700); err != nil {
		return fmt.Errorf("create archive dir: %w", err)
	}
	if err := os.Chmod(archiveDir, 0700); err != nil {
		return fmt.Errorf("chmod archive dir: %w", err)
	}
	if err := os.Chmod(filepath.Join(archiveDir, "projects"), 0700); err != nil {
		return fmt.Errorf("chmod projects dir: %w", err)
	}

	cwdVal := "/home/dev/" + proj

	// Run a minimal container that outputs all JSONL files with clear delimiters.
	// The sentinel lines start with "__" which is never valid JSON, so they are
	// unambiguous even if JSON content contains arbitrary bytes.
	const listScript = `cd /data/projects 2>/dev/null || exit 0
find . -name '*.jsonl' -type f | sort | while IFS= read -r f; do
  echo "__JSONL_FILE__"
  echo "$f"
  cat "$f"
  echo "__JSONL_END__"
done`

	uidGid := fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())
	out, code, err := runner.Output(ctx, "docker", []string{
		"run", "--rm",
		"--user", uidGid,
		"--entrypoint", "sh",
		"--volume", volume + ":/data:ro",
		image,
		"-c", listScript,
	})
	if err != nil {
		return fmt.Errorf("read volume %s: %w", volume, err)
	}
	if code != 0 {
		return fmt.Errorf("read volume %s: docker exited with code %d", volume, code)
	}

	return processOutput(out, cwdVal, destDir)
}

// processOutput parses the delimited output from the container and writes
// transformed JSONL files to destDir.
func processOutput(output, cwdVal, destDir string) error {
	lines := strings.Split(output, "\n")
	i := 0
	for i < len(lines) {
		if strings.TrimSpace(lines[i]) != "__JSONL_FILE__" {
			i++
			continue
		}
		i++
		if i >= len(lines) {
			break
		}
		filename := strings.TrimSpace(lines[i]) // e.g. "./sessions/abc.jsonl"
		i++

		// Collect lines until __JSONL_END__
		var contentLines []string
		for i < len(lines) && strings.TrimSpace(lines[i]) != "__JSONL_END__" {
			contentLines = append(contentLines, lines[i])
			i++
		}
		i++ // consume __JSONL_END__

		base := filepath.Base(filename)
		if err := writeTransformed(contentLines, cwdVal, filepath.Join(destDir, base)); err != nil {
			fmt.Fprintf(os.Stderr, "skip (parse error): %s\n", filename)
		}
	}
	return nil
}

// writeTransformed applies the allowlist transform to the JSONL lines and
// writes the result to outPath. If any line fails to parse, the whole file is
// skipped (matching the bash jq behaviour: "A file with any unparseable line
// is skipped wholesale, never copied verbatim").
func writeTransformed(lines []string, cwdVal, outPath string) error {
	tmpPath := outPath + ".tmp"
	f, err := os.Create(tmpPath)
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmpPath) }()

	w := bufio.NewWriter(f)
	for _, line := range lines {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		transformed, ok := transformRecord([]byte(line), cwdVal)
		if !ok {
			// skip silently — record has no usage data
			continue
		}
		if _, err := w.Write(transformed); err != nil {
			f.Close()
			return err
		}
		if err := w.WriteByte('\n'); err != nil {
			f.Close()
			return err
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	f.Close()
	return os.Rename(tmpPath, outPath)
}

// transformRecord applies the ccusage allowlist to a single JSONL line.
// Returns (transformed JSON bytes, true) when the record has usage data,
// or (nil, false) when it should be dropped.
//
// Mirrors the jq filter in sync-volume.sh:
//
//	if .message.usage then {timestamp, cwd, requestId, costUSD, isApiErrorMessage,
//	  message:{id, model, usage:{input_tokens, output_tokens, cache_read_input_tokens,
//	    cache_creation_input_tokens, cache_creation}}} | clean else empty end
func transformRecord(data []byte, cwdVal string) ([]byte, bool) {
	var rec map[string]interface{}
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, false
	}

	msg, _ := rec["message"].(map[string]interface{})
	if msg == nil || msg["usage"] == nil {
		return nil, false
	}

	usage, _ := msg["usage"].(map[string]interface{})
	if usage == nil {
		return nil, false
	}

	cleanUsage := pickNonNil(usage,
		"input_tokens", "output_tokens",
		"cache_read_input_tokens", "cache_creation_input_tokens",
		"cache_creation")

	cleanMsg := omitNil(map[string]interface{}{
		"id":    msg["id"],
		"model": msg["model"],
		"usage": nonNilMap(cleanUsage),
	})

	out := omitNil(map[string]interface{}{
		"timestamp":         rec["timestamp"],
		"cwd":               cwdVal,
		"requestId":         rec["requestId"],
		"costUSD":           rec["costUSD"],
		"isApiErrorMessage": rec["isApiErrorMessage"],
		"message":           nonNilMap(cleanMsg),
	})

	b, err := json.Marshal(out)
	if err != nil {
		return nil, false
	}
	return b, true
}

// pickNonNil returns a map containing only the named keys from src whose
// values are non-nil.
func pickNonNil(src map[string]interface{}, keys ...string) map[string]interface{} {
	out := make(map[string]interface{})
	for _, k := range keys {
		if v, ok := src[k]; ok && v != nil {
			out[k] = v
		}
	}
	return out
}

// omitNil returns a copy of m with nil-valued entries removed.
func omitNil(m map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{})
	for k, v := range m {
		if v != nil {
			out[k] = v
		}
	}
	return out
}

// nonNilMap returns nil if m is empty (so omitNil will drop the parent key).
func nonNilMap(m map[string]interface{}) interface{} {
	if len(m) == 0 {
		return nil
	}
	return m
}

// ProjNameFromVolume extracts the project name from a volume name.
// Mirrors usage.sh: strip "claude-" prefix, strip last "-<hash>" component.
// Falls back to the full volume name if the pattern doesn't match.
func ProjNameFromVolume(v string) string {
	tmp := strings.TrimPrefix(v, "claude-")
	if tmp == v {
		return v // no claude- prefix
	}
	idx := strings.LastIndex(tmp, "-")
	if idx <= 0 {
		return v // no dash or dash at start
	}
	proj := tmp[:idx]
	if proj == "" {
		return v
	}
	return proj
}

// ListSessionVolumes returns all Docker volume names starting with "claude-".
func ListSessionVolumes() ([]string, error) {
	out, err := exec.Command("docker", "volume", "ls", "--quiet").Output()
	if err != nil {
		return nil, fmt.Errorf("list volumes: %w", err)
	}
	var result []string
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "claude-") {
			result = append(result, line)
		}
	}
	return result, nil
}

// RunCCUsage execs ccusage (global install preferred, npx fallback) with
// CLAUDE_CONFIG_DIR set to archiveDir. args are forwarded verbatim.
// This function does not return on success (it replaces the process).
func RunCCUsage(archiveDir, ccusageVersion string, args []string, stdout, stderr io.Writer) error {
	if ccusageVersion == "" {
		ccusageVersion = "latest"
	}

	// Prefer globally installed ccusage
	if path, err := exec.LookPath("ccusage"); err == nil {
		cmd := exec.Command(path, args...)
		cmd.Env = append(os.Environ(), "CLAUDE_CONFIG_DIR="+archiveDir)
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		return cmd.Run()
	}

	// Fallback to npx
	npxArgs := []string{"--yes", "ccusage@" + ccusageVersion}
	npxArgs = append(npxArgs, args...)
	cmd := exec.Command("npx", npxArgs...)
	cmd.Env = append(os.Environ(), "CLAUDE_CONFIG_DIR="+archiveDir)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}
