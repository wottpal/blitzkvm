package logging

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

const (
	defaultLevel = zerolog.ErrorLevel
	envLogLevel  = "JETKVM_DESKTOP_LOG_LEVEL"

	// maxLogFileSize bounds the log file; on open, a larger file is rotated to <name>.1.
	maxLogFileSize = 10 << 20
)

var (
	mu     sync.RWMutex
	level            = defaultLevel
	output io.Writer = zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.RFC3339}
	base             = zerolog.New(output).Level(level).With().Timestamp().Logger()
)

func Configure(levelText string) error {
	parsed := defaultLevel
	if value := strings.TrimSpace(levelText); value != "" {
		l, err := zerolog.ParseLevel(strings.ToLower(value))
		if err != nil {
			return fmt.Errorf("invalid log level %q: %w", value, err)
		}
		parsed = l
	} else if value := strings.TrimSpace(os.Getenv(envLogLevel)); value != "" {
		l, err := zerolog.ParseLevel(strings.ToLower(value))
		if err != nil {
			return fmt.Errorf("invalid %s %q: %w", envLogLevel, value, err)
		}
		parsed = l
	}

	mu.Lock()
	level = parsed
	base = zerolog.New(output).Level(level).With().Timestamp().Logger()
	mu.Unlock()
	return nil
}

// SetOutput redirects all subsequent loggers to w. Console output is
// human-readable; anything else (files, pipes) receives JSON lines.
func SetOutput(w io.Writer, console bool) {
	mu.Lock()
	defer mu.Unlock()
	if console {
		output = zerolog.ConsoleWriter{Out: w, TimeFormat: time.RFC3339, NoColor: true}
	} else {
		output = w
	}
	base = zerolog.New(output).Level(level).With().Timestamp().Logger()
}

func Subsystem(name string) zerolog.Logger {
	mu.RLock()
	logger := base.With().Str("component", name).Logger()
	mu.RUnlock()
	return logger
}

// StderrIsTerminal reports whether stderr is attached to a terminal. Apps
// launched from Finder or by a parent process get a pipe or /dev/null.
func StderrIsTerminal() bool {
	info, err := os.Stderr.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// DefaultLogDir returns ~/Library/Logs/jetkvm-desktop on macOS and a
// per-user cache directory elsewhere.
func DefaultLogDir() (string, error) {
	if runtime.GOOS == "darwin" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, "Library", "Logs", "jetkvm-desktop"), nil
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cache, "jetkvm-desktop", "logs"), nil
}

// OpenLogFile opens (appending) <DefaultLogDir>/<name>.log, rotating it to
// <name>.log.1 first when it has grown beyond maxLogFileSize.
func OpenLogFile(name string) (*os.File, error) {
	dir, err := DefaultLogDir()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, name+".log")
	if info, err := os.Stat(path); err == nil && info.Size() > maxLogFileSize {
		_ = os.Rename(path, path+".1")
	}
	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
}

// EnableCrashOutput makes the Go runtime write fatal-error and unrecovered
// panic reports to f in addition to stderr, so crashes of processes without a
// terminal leave a trace.
func EnableCrashOutput(f *os.File) error {
	return debug.SetCrashOutput(f, debug.CrashOptions{})
}
