package config

import (
	"os"
	"path/filepath"

	"github.com/MrOggy85/claude-in-docker/internal/mounts"
)

const (
	DefaultImage          = "claude-code:local"
	DefaultHomeInContainer = "/home/dev"
)

// Config holds all runtime configuration read from the environment.
// Configuration comes exclusively from env vars — no flags are parsed.
type Config struct {
	// Fixed container layout
	Image           string
	HomeInContainer string
	RepoInContainer string

	// Host paths
	ScriptDir  string // dir containing the binary (= build context)
	ProjectDir string // working directory when the binary was invoked
	HomeDir    string // host $HOME

	// Volume / container identity
	ClaudeVolume    string // CLAUDE_VOLUME — overrides computed volume name
	ContainerName   string // CLAUDE_CONTAINER_NAME — overrides computed name

	// Extra mounts and ports
	ClaudeMounts string // CLAUDE_MOUNTS
	ClaudePorts  string // CLAUDE_PORTS

	// Volume-backed in-repo paths
	SkipVolumePaths  string // SKIP_CLAUDE_VOLUME_PATHS (non-empty = skip)
	ClaudeVolumePaths string // CLAUDE_VOLUME_PATHS (comma-separated)

	// Usage sync
	AutoUsage bool   // parsed from CLAUDE_AUTO_USAGE (default true)
	UsageDir  string // CLAUDE_USAGE_DIR (default ~/.claude-docker-usage)

	// Pass-through env vars (read here so they can be used in logic; forwarded
	// to the container as passthroughs in the docker run command).
	McpGhBearer string // MCP_GH_BEARER
}

// Load reads configuration from the environment.
// scriptDir is the directory containing the running binary.
// projectDir is the current working directory.
func Load(scriptDir, projectDir string) Config {
	homeInContainer := DefaultHomeInContainer
	return Config{
		Image:            DefaultImage,
		HomeInContainer:  homeInContainer,
		RepoInContainer:  homeInContainer + "/repo",
		ScriptDir:        scriptDir,
		ProjectDir:       projectDir,
		HomeDir:          os.Getenv("HOME"),
		ClaudeVolume:     os.Getenv("CLAUDE_VOLUME"),
		ContainerName:    os.Getenv("CLAUDE_CONTAINER_NAME"),
		ClaudeMounts:     os.Getenv("CLAUDE_MOUNTS"),
		ClaudePorts:      os.Getenv("CLAUDE_PORTS"),
		SkipVolumePaths:  os.Getenv("SKIP_CLAUDE_VOLUME_PATHS"),
		ClaudeVolumePaths: os.Getenv("CLAUDE_VOLUME_PATHS"),
		AutoUsage:        mounts.ParseAutoUsage(os.Getenv("CLAUDE_AUTO_USAGE")),
		UsageDir:         usageDir(),
		McpGhBearer:      os.Getenv("MCP_GH_BEARER"),
	}
}

func usageDir() string {
	if d := os.Getenv("CLAUDE_USAGE_DIR"); d != "" {
		return d
	}
	return filepath.Join(os.Getenv("HOME"), ".claude-docker-usage")
}
