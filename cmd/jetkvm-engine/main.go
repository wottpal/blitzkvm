// Command jetkvm-engine is the helper process of the native macOS app: one
// instance per device session, speaking pkg/engineipc on stdin/stdout. Logs
// and crash output go to stderr, which the app writes to its log file.
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
	// Logs (JSON lines) and crash reports go to stderr; the app forwards
	// them into its own log file. Several helpers run at once, so they must
	// not share and rotate a file themselves.
	logging.SetOutput(os.Stderr, false)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := engine.Run(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "jetkvm-engine:", err)
		os.Exit(1)
	}
}
