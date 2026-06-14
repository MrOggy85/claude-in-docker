// Command claude runs Claude Code inside a hardened Docker container as the
// host user. It is the Go replacement for run.sh.
//
// Configuration comes exclusively from environment variables — no flags are
// parsed. All arguments are forwarded verbatim to `claude` inside the container.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/MrOggy85/claude-in-docker/internal/config"
	"github.com/MrOggy85/claude-in-docker/internal/docker"
	"github.com/MrOggy85/claude-in-docker/internal/mounts"
	"github.com/MrOggy85/claude-in-docker/internal/naming"
	"github.com/MrOggy85/claude-in-docker/internal/usagesync"
)

func main() {
	os.Exit(run(os.Args[1:], docker.RealRunner{}))
}

func run(args []string, runner docker.Runner) int {
	ctx := context.Background()

	// Resolve the binary's own directory as the build context (= SCRIPT_DIR in bash).
	execPath, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, ">> error resolving executable path:", err)
		return 1
	}
	scriptDir := filepath.Dir(execPath)

	projectDir, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, ">> error getting working directory:", err)
		return 1
	}

	cfg := config.Load(scriptDir, projectDir)

	// 1. Build the image if the context has changed (or image doesn't exist).
	if err := buildIfNeeded(ctx, runner, cfg); err != nil {
		fmt.Fprintln(os.Stderr, ">> error building image:", err)
		return 1
	}

	// 2. Stable per-project volume name and throwaway container name.
	safeName := naming.SafeName(projectDir)
	volumeName := cfg.ClaudeVolume
	if volumeName == "" {
		volumeName = naming.VolumeName(safeName, projectDir)
	}
	containerName := cfg.ContainerName
	if containerName == "" {
		containerName = naming.ContainerName(safeName)
	}
	fmt.Fprintf(os.Stderr, ">> session volume: %s  (docker volume inspect %s)\n", volumeName, volumeName)
	fmt.Fprintf(os.Stderr, ">> container name: %s\n", containerName)

	// 3. Ensure credentials file exists (seeded with "{}" if absent).
	if err := docker.EnsureCredentials(scriptDir); err != nil {
		fmt.Fprintln(os.Stderr, ">> error ensuring credentials:", err)
		return 1
	}

	// 3a. Config file mounts (settings.json, claude.json, .credentials.json, etc.)
	configMountArgs := docker.ConfigMounts(scriptDir, cfg.HomeInContainer, os.Stderr)

	// 3b. Extra mounts from CLAUDE_MOUNTS.
	extraMountArgs := mounts.ParseMounts(
		cfg.ClaudeMounts,
		cfg.HomeDir,
		projectDir,
		cfg.HomeInContainer,
		cfg.RepoInContainer,
		os.Stderr,
	)

	// 3c. Published ports from CLAUDE_PORTS.
	portSpecs := mounts.ParsePorts(cfg.ClaudePorts, os.Stderr)
	var publishArgs []string
	var openPorts []string
	for _, ps := range portSpecs {
		publishArgs = append(publishArgs, ps.PublishArg)
		openPorts = append(openPorts, ps.ContainerPort)
	}
	containerOpenPorts := strings.Join(openPorts, ",")

	// 3d. In-repo volume-backed paths (node_modules etc.)
	volumePathMounts, err := docker.PreparePathVolumes(ctx, docker.PathVolumeConfig{
		SkipVolumePaths:   cfg.SkipVolumePaths,
		ClaudeVolumePaths: cfg.ClaudeVolumePaths,
		ScriptDir:         scriptDir,
		ProjectDir:        projectDir,
		SafeName:          safeName,
		RepoInContainer:   cfg.RepoInContainer,
		Image:             cfg.Image,
		UID:               os.Getuid(),
		GID:               os.Getgid(),
	}, runner, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, ">> error preparing path volumes:", err)
		return 1
	}

	// 4. Run the container (interactive, inherits stdio).
	runArgs := docker.BuildRunArgs(docker.RunConfig{
		ContainerName:      containerName,
		UserUID:            fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()),
		HomeInContainer:    cfg.HomeInContainer,
		RepoInContainer:    cfg.RepoInContainer,
		ContainerOpenPorts: containerOpenPorts,
		PublishArgs:        publishArgs,
		ProjectDir:         projectDir,
		VolumePathMounts:   volumePathMounts,
		VolumeName:         volumeName,
		ConfigMounts:       configMountArgs,
		ExtraMounts:        extraMountArgs,
		Image:              cfg.Image,
		ClaudeArgs:         args,
	})

	exitCode, err := runner.Run(ctx, "docker", runArgs, true)
	if err != nil {
		fmt.Fprintln(os.Stderr, ">> error running container:", err)
		return 1
	}

	// 5. Usage sync (runs after the session regardless of exit code).
	if cfg.AutoUsage {
		if err := usagesync.SyncVolume(ctx, runner, cfg.Image, volumeName, safeName, cfg.UsageDir); err != nil {
			fmt.Fprintf(os.Stderr, ">> WARNING: usage sync failed — run %s/usage.sh to retry\n", scriptDir)
		}
	}

	return exitCode
}

// buildIfNeeded rebuilds the Docker image when the build context has changed.
func buildIfNeeded(ctx context.Context, runner docker.Runner, cfg config.Config) error {
	currentHash, err := naming.ContextHash(cfg.ScriptDir)
	if err != nil {
		return err
	}

	imageHash := docker.GetImageLabel(ctx, runner, cfg.Image, "build.context-hash")

	if imageHash == currentHash {
		return nil // up to date
	}

	if imageHash != "" {
		fmt.Fprintf(os.Stderr, ">> Build context changed — rebuilding %s...\n", cfg.Image)
	} else {
		fmt.Fprintf(os.Stderr, ">> Building %s...\n", cfg.Image)
	}

	buildArgs := docker.BuildImageArgs(cfg.Image, currentHash, cfg.ScriptDir)
	code, err := runner.Run(ctx, "docker", buildArgs, false)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("docker build exited with code %d", code)
	}
	return nil
}
