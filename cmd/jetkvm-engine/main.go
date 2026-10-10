// Command jetkvm-engine is the helper process of the native macOS app: one
// instance per device session, speaking pkg/engineipc on stdin/stdout. Logs go
// to stderr (the app captures them) and, without a terminal, to
// ~/Library/Logs/jetkvm-desktop/engine.log.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/lkarlslund/jetkvm-desktop/pkg/engine"
	"github.com/lkarlslund/jetkvm-desktop/pkg/logging"
)

func main() {
	logLevel := flag.String("log-level", "", "error, warn, info, debug or trace")
	flag.Parse()
	if err := logging.Configure(*logLevel); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if f, err := logging.OpenLogFile("engine"); err == nil {
		defer f.Close()
		logging.SetOutput(f, false)
		_ = logging.EnableCrashOutput(f)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := engine.Run(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "jetkvm-engine:", err)
		os.Exit(1)
	}
}
