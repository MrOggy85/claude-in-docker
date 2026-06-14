package docker

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/MrOggy85/claude-in-docker/internal/naming"
)

// BuildImageArgs returns the arg slice for `docker build`.
func BuildImageArgs(image, contextHash, scriptDir string) []string {
	return []string{
		"build",
		"--tag", image,
		"--label", "build.context-hash=" + contextHash,
		scriptDir,
	}
}

// GetImageLabel inspects an image label. Returns "" when the image doesn't exist.
func GetImageLabel(ctx context.Context, runner Runner, image, label string) string {
	format := fmt.Sprintf("{{index .Config.Labels %q}}", label)
	out, code, _ := runner.Output(ctx, "docker", []string{"image", "inspect", image, "--format", format})
	if code != 0 {
		return ""
	}
	return strings.TrimSpace(out)
}

// RunConfig holds all parameters for BuildRunArgs.
type RunConfig struct {
	ContainerName      string
	UserUID            string   // "UID:GID"
	HomeInContainer    string
	RepoInContainer    string
	ContainerOpenPorts string
	PublishArgs        []string // each entry: the publish spec (no --publish flag)
	ProjectDir         string
	VolumePathMounts   []string // flat: "--volume", "name:target", ...
	VolumeName         string
	ConfigMounts       []string // flat: "--volume", "host:container[:ro]", ...
	ExtraMounts        []string // flat: "--volume", "host:target:mode", ...
	Image              string
	ClaudeArgs         []string // forwarded verbatim to claude inside container
}

// BuildRunArgs returns the complete arg slice for `docker run`.
// All args are returned as separate string elements suitable for exec.Command.
func BuildRunArgs(cfg RunConfig) []string {
	args := []string{"run"}
	args = append(args, "--name", cfg.ContainerName)
	args = append(args, "--interactive", "--tty", "--rm")
	args = append(args, "--user", cfg.UserUID)
	args = append(args, "--cap-add=NET_ADMIN")
	args = append(args, "--env", "HOME="+cfg.HomeInContainer)
	args = append(args, "--env", "COLORTERM=truecolor")
	args = append(args, "--env", "MCP_GH_BEARER") // passthrough from host env
	args = append(args, "--env", "CONTAINER_OPEN_PORTS="+cfg.ContainerOpenPorts)

	for _, pub := range cfg.PublishArgs {
		args = append(args, "--publish", pub)
	}

	args = append(args, "--volume", cfg.ProjectDir+":"+cfg.RepoInContainer)
	args = append(args, cfg.VolumePathMounts...)
	args = append(args, "--volume", cfg.VolumeName+":"+cfg.HomeInContainer+"/.claude")
	args = append(args, cfg.ConfigMounts...)
	args = append(args, cfg.ExtraMounts...)
	args = append(args, "--workdir", cfg.RepoInContainer)
	args = append(args, cfg.Image)
	args = append(args, "claude")
	args = append(args, cfg.ClaudeArgs...)

	return args
}

// ConfigMounts builds the optional config file mount args for the SCRIPT_DIR files.
// Returns a flat []string of "--volume", "HOST:CONTAINER[:ro]" pairs.
// Files that don't exist on the host are skipped with a notice to stderr.
// Mirrors run.sh steps 3 and credentials seeding.
func ConfigMounts(scriptDir, homeInContainer string, stderr io.Writer) []string {
	type mountDef struct {
		host     string
		container string
		readOnly bool
	}

	credFile := filepath.Join(scriptDir, ".credentials.json")
	defs := []mountDef{
		{filepath.Join(scriptDir, "settings.json"),        filepath.Join(homeInContainer, ".claude/settings.json"), true},
		{filepath.Join(scriptDir, "claude.json"),          filepath.Join(homeInContainer, ".claude.json"),          false},
		{credFile,                                          filepath.Join(homeInContainer, ".claude/.credentials.json"), false},
		{filepath.Join(scriptDir, "container-CLAUDE.md"),  filepath.Join(homeInContainer, ".claude/CLAUDE.md"),     true},
		{filepath.Join(scriptDir, ".gitconfig"),           filepath.Join(homeInContainer, ".gitconfig"),            true},
	}

	var result []string
	for _, d := range defs {
		if _, err := os.Stat(d.host); err != nil {
			fmt.Fprintf(stderr, ">> skipping (not found on host): %s\n", d.host)
			continue
		}
		val := d.host + ":" + d.container
		if d.readOnly {
			val += ":ro"
		}
		result = append(result, "--volume", val)
	}
	return result
}

// EnsureCredentials creates SCRIPT_DIR/.credentials.json with content "{}" and
// mode 0600 if it does not exist, so Docker bind-mounts it as a file.
// Mirrors run.sh: [ -e "$CRED_FILE" ] || { printf '{}' > "$CRED_FILE"; chmod 600 "$CRED_FILE"; }
func EnsureCredentials(scriptDir string) error {
	credFile := filepath.Join(scriptDir, ".credentials.json")
	if _, err := os.Stat(credFile); err == nil {
		return nil // already exists
	}
	if err := os.WriteFile(credFile, []byte("{}"), 0600); err != nil {
		return fmt.Errorf("create credentials file: %w", err)
	}
	return nil
}

// PathVolumeConfig holds parameters for PreparePathVolumes.
type PathVolumeConfig struct {
	SkipVolumePaths   string // SKIP_CLAUDE_VOLUME_PATHS env var
	ClaudeVolumePaths string // CLAUDE_VOLUME_PATHS env var
	ScriptDir         string
	ProjectDir        string
	SafeName          string
	RepoInContainer   string
	Image             string
	UID               int
	GID               int
}

// PreparePathVolumes creates named Docker volumes for in-repo paths (e.g. node_modules),
// ensuring they are owned by the host UID/GID, and returns the flat mount arg pairs.
// Mirrors run.sh section 3d.
func PreparePathVolumes(ctx context.Context, cfg PathVolumeConfig, runner Runner, stderr io.Writer) ([]string, error) {
	if cfg.SkipVolumePaths != "" {
		fmt.Fprintf(stderr, ">> SKIP_CLAUDE_VOLUME_PATHS set — not isolating in-repo paths; node_modules etc. will land on the host\n")
		return nil, nil
	}

	safeName := cfg.SafeName
	if safeName == "" {
		safeName = "repo"
	}

	seen := map[string]bool{}
	var result []string

	var processPath func(rel string) error
	processPath = func(rel string) error {
		// Validate: must be repo-relative (no absolute, no ..)
		if filepath.IsAbs(rel) || strings.Contains(rel, "..") {
			fmt.Fprintf(stderr, ">> skipping volume path (must be repo-relative, no '..'): %s\n", rel)
			return nil
		}
		if seen[rel] {
			return nil
		}
		seen[rel] = true

		// Warn if host already has contents
		hostPath := filepath.Join(cfg.ProjectDir, rel)
		entries, _ := os.ReadDir(hostPath)
		if len(entries) > 0 {
			fmt.Fprintf(stderr, ">> WARNING: %s already has contents on the host; the volume hides them in the container but the host copy remains — delete it to keep the host clean.\n", rel)
		}

		volName := "claude-vol-" + safeName + "-" + naming.PathHash(filepath.Join(cfg.ProjectDir, rel))
		target := cfg.RepoInContainer + "/" + rel

		// Create volume if it doesn't exist
		code, err := runner.Run(ctx, "docker", []string{"volume", "inspect", volName}, false)
		if err != nil {
			return fmt.Errorf("inspect volume %s: %w", volName, err)
		}
		if code != 0 {
			if _, err := runner.Run(ctx, "docker", []string{"volume", "create", volName}, false); err != nil {
				return fmt.Errorf("create volume %s: %w", volName, err)
			}
			uidGid := fmt.Sprintf("%d:%d", cfg.UID, cfg.GID)
			if _, err := runner.Run(ctx, "docker", []string{
				"run", "--rm", "--user", "0:0", "--entrypoint", "chown",
				"--volume", volName + ":/v",
				cfg.Image, uidGid, "/v",
			}, false); err != nil {
				return fmt.Errorf("chown volume %s: %w", volName, err)
			}
			fmt.Fprintf(stderr, ">> created path volume: %s -> %s\n", volName, target)
		}

		result = append(result, "--volume", volName+":"+target)
		return nil
	}

	// expandAuto calls find-node-modules-paths.sh for automatic node_modules detection.
	expandAuto := func() {
		scriptPath := filepath.Join(cfg.ScriptDir, "scripts", "find-node-modules-paths.sh")
		out, code, err := runner.Output(ctx, scriptPath, []string{cfg.ProjectDir})
		if err != nil || code != 0 {
			return
		}
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			line = strings.TrimSpace(line)
			if line != "" {
				_ = processPath(line)
			}
		}
	}

	expandAuto()

	if cfg.ClaudeVolumePaths != "" {
		for _, rel := range strings.Split(cfg.ClaudeVolumePaths, ",") {
			rel = strings.TrimSpace(rel)
			rel = strings.TrimPrefix(rel, "./")
			rel = strings.TrimSuffix(rel, "/")
			if rel == "" {
				continue
			}
			if rel == "auto" {
				expandAuto()
			} else {
				_ = processPath(rel)
			}
		}
	}

	return result, nil
}
