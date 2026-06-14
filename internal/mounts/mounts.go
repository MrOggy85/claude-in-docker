package mounts

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ParseAutoUsage returns false when val is one of "0", "false", "no", "off"
// (case-insensitive), true otherwise (including empty → default on).
// Matches run.sh: case "${CLAUDE_AUTO_USAGE:-1}" in 0|false|no|off|...) AUTO_USAGE=0.
func ParseAutoUsage(val string) bool {
	switch strings.ToLower(val) {
	case "0", "false", "no", "off":
		return false
	default:
		return true
	}
}

// ParseMounts parses the CLAUDE_MOUNTS comma-separated list into --volume token pairs
// (each returned as two consecutive strings: "--volume", "HOST:TARGET:MODE").
// Mirrors the logic in scripts/extra-mounts.sh.
//
// Parameters:
//   - claudeMounts: value of CLAUDE_MOUNTS env var
//   - homeDir: host $HOME for ~ expansion
//   - projectDir: host project directory for relative-path resolution
//   - homeInContainer: container home dir (e.g. /home/dev)
//   - repoInContainer: container repo mount point (reserved target)
//   - stderr: for human-readable progress/skip messages
func ParseMounts(claudeMounts, homeDir, projectDir, homeInContainer, repoInContainer string, stderr io.Writer) []string {
	if claudeMounts == "" {
		return nil
	}

	usedTargets := map[string]bool{
		repoInContainer:                             true,
		filepath.Join(homeInContainer, ".claude"): true,
	}

	var result []string
	for _, entry := range strings.Split(claudeMounts, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}

		// Optional :rw / :ro suffix (default read-only)
		mode := "ro"
		switch {
		case strings.HasSuffix(entry, ":rw"):
			mode = "rw"
			entry = entry[:len(entry)-3]
		case strings.HasSuffix(entry, ":ro"):
			entry = entry[:len(entry)-3]
		}

		// Expand leading ~ and resolve relative paths
		switch {
		case entry == "~":
			entry = homeDir
		case strings.HasPrefix(entry, "~/"):
			entry = filepath.Join(homeDir, entry[2:])
		case filepath.IsAbs(entry):
			// already absolute, keep as-is
		default:
			entry = filepath.Join(projectDir, entry)
		}

		// Check existence
		if _, err := os.Stat(entry); err != nil {
			fmt.Fprintf(stderr, ">> skipping extra mount (not found on host): %s\n", entry)
			continue
		}

		// Canonicalise without relying on realpath (mirrors the bash cd+pwd trick).
		var host string
		fi, err := os.Stat(entry)
		if err != nil {
			fmt.Fprintf(stderr, ">> skipping extra mount (stat error): %s\n", entry)
			continue
		}
		if fi.IsDir() {
			abs, err := filepath.Abs(entry)
			if err != nil {
				fmt.Fprintf(stderr, ">> skipping extra mount (abs error): %s\n", entry)
				continue
			}
			host = abs
		} else {
			dirAbs, err := filepath.Abs(filepath.Dir(entry))
			if err != nil {
				fmt.Fprintf(stderr, ">> skipping extra mount (abs dir error): %s\n", entry)
				continue
			}
			host = filepath.Join(dirAbs, filepath.Base(entry))
		}

		base := filepath.Base(host)
		target := filepath.Join(homeInContainer, base)

		if usedTargets[target] {
			fmt.Fprintf(stderr, ">> skipping extra mount (target %s already in use): %s\n", target, host)
			continue
		}
		usedTargets[target] = true

		fmt.Fprintf(stderr, ">> extra mount (%s): %s -> %s\n", mode, host, target)
		result = append(result, "--volume", host+":"+target+":"+mode)
	}
	return result
}

// PortSpec holds a parsed port entry from CLAUDE_PORTS.
type PortSpec struct {
	PublishArg    string // docker run --publish value, e.g. "8080:8080/tcp"
	ContainerPort string // container port/proto for firewall, e.g. "8080/tcp"
}

// ParsePorts parses the CLAUDE_PORTS comma-separated list into PortSpec entries.
// Mirrors the logic in scripts/extra-ports.sh.
//
// Entry syntax (per comma-separated item):
//
//	PORT              → publish PORT:PORT (host 0.0.0.0)
//	HOSTPORT:CPORT    → publish HOSTPORT:CPORT
//	IP:HOSTPORT:CPORT → publish IP:HOSTPORT:CPORT
//
// Optional /tcp (default) or /udp suffix.
func ParsePorts(claudePorts string, stderr io.Writer) []PortSpec {
	if claudePorts == "" {
		return nil
	}

	isPort := func(s string) bool {
		n, err := strconv.Atoi(s)
		return err == nil && n >= 1 && n <= 65535
	}

	var result []PortSpec
	for _, entry := range strings.Split(claudePorts, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}

		// Optional /tcp | /udp suffix (default tcp)
		proto := "tcp"
		switch {
		case strings.HasSuffix(entry, "/tcp"):
			entry = entry[:len(entry)-4]
		case strings.HasSuffix(entry, "/udp"):
			proto = "udp"
			entry = entry[:len(entry)-4]
		case strings.Contains(entry, "/"):
			fmt.Fprintf(stderr, ">> skipping port (unknown protocol, use /tcp or /udp): %s\n", entry)
			continue
		}

		// Split on ":" → 1, 2, or 3 fields
		parts := strings.Split(entry, ":")
		var ip, hport, cport string
		switch len(parts) {
		case 1:
			hport = parts[0]
			cport = parts[0]
		case 2:
			hport = parts[0]
			cport = parts[1]
		case 3:
			ip = parts[0]
			hport = parts[1]
			cport = parts[2]
		default:
			fmt.Fprintf(stderr, ">> skipping port (too many ':' fields): %s\n", entry)
			continue
		}

		if !isPort(hport) || !isPort(cport) {
			fmt.Fprintf(stderr, ">> skipping port (not a valid 1-65535 port): %s\n", entry)
			continue
		}

		var spec string
		if ip != "" {
			spec = fmt.Sprintf("%s:%s:%s/%s", ip, hport, cport, proto)
			fmt.Fprintf(stderr, ">> publish (%s): host %s:%s -> container %s\n", proto, ip, hport, cport)
		} else {
			spec = fmt.Sprintf("%s:%s/%s", hport, cport, proto)
			fmt.Fprintf(stderr, ">> publish (%s): host %s -> container %s\n", proto, hport, cport)
		}

		result = append(result, PortSpec{
			PublishArg:    spec,
			ContainerPort: cport + "/" + proto,
		})
	}
	return result
}
