package naming

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// SafeName sanitizes a project directory path into a Docker-safe name component.
// Matches run.sh: lowercase basename, non-[a-z0-9] → '-', runs collapsed, ends trimmed.
func SafeName(projectDir string) string {
	base := strings.ToLower(filepath.Base(projectDir))
	var buf strings.Builder
	for _, r := range base {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			buf.WriteRune(r)
		} else {
			buf.WriteRune('-')
		}
	}
	s := buf.String()
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-")
	}
	return strings.Trim(s, "-")
}

// PathHash returns the first 10 lowercase hex characters of the SHA-256 hash
// of the given path string (no trailing newline), matching run.sh's path_hash().
// In Go: crypto/sha256 over []byte(path), hex.EncodeToString, take [:10].
func PathHash(path string) string {
	h := sha256.Sum256([]byte(path))
	return hex.EncodeToString(h[:])[:10]
}

// VolumeName returns the stable Docker volume name for a project.
// Matches run.sh: claude-<SAFE_NAME>-<path_hash(PROJECT_DIR)>.
// Uses "repo" if safeName is empty.
func VolumeName(safeName, projectDir string) string {
	if safeName == "" {
		safeName = "repo"
	}
	return fmt.Sprintf("claude-%s-%s", safeName, PathHash(projectDir))
}

// ContainerName returns a unique container name with a random 8-hex-char suffix.
// Matches run.sh: claude-<SAFE_NAME>-<4hex><4hex>.
// Uses "repo" if safeName is empty.
func ContainerName(safeName string) string {
	if safeName == "" {
		safeName = "repo"
	}
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		// fallback: xor of pid bytes
		pid := os.Getpid()
		b[0] = byte(pid)
		b[1] = byte(pid >> 8)
		b[2] = byte(pid >> 16)
		b[3] = byte(pid >> 24)
	}
	return fmt.Sprintf("claude-%s-%x", safeName, b)
}

// ContextHash hashes the build context files deterministically for build-if-changed.
// Uses sha256 of each file's content (with path as prefix), combined into one hash.
// Returns the first 16 lowercase hex chars.
// Exact-byte parity with the bash version is not required; any mismatch just triggers
// one harmless rebuild that self-heals.
func ContextHash(scriptDir string) (string, error) {
	files := []string{
		filepath.Join(scriptDir, "Dockerfile"),
		filepath.Join(scriptDir, "entrypoint.sh"),
		filepath.Join(scriptDir, "init-firewall.sh"),
		filepath.Join(scriptDir, "allowed-domains.txt"),
		filepath.Join(scriptDir, "install_additional_packages.sh"),
	}
	outer := sha256.New()
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue // skip files that don't exist
		}
		inner := sha256.Sum256(data)
		// Format matches sha256sum output: "<hex>  <path>\n"
		fmt.Fprintf(outer, "%x  %s\n", inner, f)
	}
	return hex.EncodeToString(outer.Sum(nil))[:16], nil
}
