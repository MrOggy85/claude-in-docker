// Command claude-usage aggregates ccusage across all claude-* Docker session
// volumes and runs ccusage over the combined archive. It is the Go replacement
// for usage.sh.
//
// Usage:
//
//	claude-usage                # monthly report (default)
//	claude-usage daily          # any ccusage subcommand / flags pass through
//	claude-usage monthly --json
//
// Environment:
//
//	CLAUDE_USAGE_DIR   where to keep the aggregated logs (default: ~/.claude-docker-usage)
//	CCUSAGE_VERSION    npm version for the npx fallback (default: latest)
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/MrOggy85/claude-in-docker/internal/docker"
	"github.com/MrOggy85/claude-in-docker/internal/usagesync"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	ctx := context.Background()
	runner := docker.RealRunner{}
	image := "claude-code:local"

	archiveDir := os.Getenv("CLAUDE_USAGE_DIR")
	if archiveDir == "" {
		archiveDir = filepath.Join(os.Getenv("HOME"), ".claude-docker-usage")
	}
	ccusageVersion := os.Getenv("CCUSAGE_VERSION")

	// All claude-* session volumes created by run.sh / claude binary.
	volumes, err := usagesync.ListSessionVolumes()
	if err != nil {
		fmt.Fprintln(os.Stderr, ">> error listing volumes:", err)
		return 1
	}
	if len(volumes) == 0 {
		fmt.Fprintln(os.Stderr, "No claude-* session volumes found — run a session via ./claude (or ./run.sh) first.")
		return 1
	}

	fmt.Fprintf(os.Stderr, ">> Collecting transcripts from %d session volume(s) into %s\n", len(volumes), archiveDir)
	for _, v := range volumes {
		proj := usagesync.ProjNameFromVolume(v)
		if err := usagesync.SyncVolume(ctx, runner, image, v, proj, archiveDir); err != nil {
			fmt.Fprintf(os.Stderr, ">> WARNING: sync failed for %s: %v\n", v, err)
		}
	}

	fmt.Fprintf(os.Stderr, ">> Running ccusage over %s\n", archiveDir)

	// Default subcommand when no args given, matching usage.sh behaviour.
	ccusageArgs := args
	if len(ccusageArgs) == 0 {
		ccusageArgs = []string{"monthly"}
	}

	if err := usagesync.RunCCUsage(archiveDir, ccusageVersion, ccusageArgs, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, ">> ccusage error:", err)
		return 1
	}
	return 0
}
