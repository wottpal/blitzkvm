package logging

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

const (
	defaultLevel = zerolog.ErrorLevel
	envLogLevel  = "BLITZKVM_LOG_LEVEL"

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
