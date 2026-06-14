package docker

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
)

// Runner abstracts command execution so that callers can be tested without
// invoking Docker or the network.
type Runner interface {
	// Run executes a command, inheriting the process stdio when interactive is
	// true (for docker run sessions), otherwise attaching only stderr so
	// progress messages pass through. Returns the command's exit code; err is
	// non-nil only for execution failures (failed to start, etc.), not for
	// non-zero exit codes.
	Run(ctx context.Context, name string, args []string, interactive bool) (int, error)

	// Output executes a command and captures its stdout. Returns (stdout, exitCode, err).
	Output(ctx context.Context, name string, args []string) (string, int, error)
}

// RealRunner executes commands using os/exec.
type RealRunner struct{}

func (r RealRunner) Run(ctx context.Context, name string, args []string, interactive bool) (int, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if interactive {
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	} else {
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return exitErr.ExitCode(), nil
		}
		return 1, err
	}
	return 0, nil
}

func (r RealRunner) Output(ctx context.Context, name string, args []string) (string, int, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return stdout.String(), exitErr.ExitCode(), nil
		}
		return "", 1, err
	}
	return stdout.String(), 0, nil
}

// FakeRunner records calls for testing. It never invokes real commands.
type FakeRunner struct {
	Commands  []FakeCall
	ExitCodes []int // exit codes to return in order; 0 for any beyond the list
	Outputs   []string // stdout values for Output calls
	outIdx    int
	codeIdx   int
}

// FakeCall records a single command invocation.
type FakeCall struct {
	Name        string
	Args        []string
	Interactive bool
	IsOutput    bool // true when called via Output()
}

func (f *FakeRunner) Run(ctx context.Context, name string, args []string, interactive bool) (int, error) {
	f.Commands = append(f.Commands, FakeCall{Name: name, Args: args, Interactive: interactive})
	return f.nextCode(), nil
}

func (f *FakeRunner) Output(ctx context.Context, name string, args []string) (string, int, error) {
	f.Commands = append(f.Commands, FakeCall{Name: name, Args: args, IsOutput: true})
	out := ""
	if f.outIdx < len(f.Outputs) {
		out = f.Outputs[f.outIdx]
		f.outIdx++
	}
	return out, f.nextCode(), nil
}

func (f *FakeRunner) nextCode() int {
	if f.codeIdx < len(f.ExitCodes) {
		c := f.ExitCodes[f.codeIdx]
		f.codeIdx++
		return c
	}
	return 0
}
