package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/wottpal/blitzkvm/pkg/emulator"
)

func main() {
	cfg := emulator.Config{}
	logInputs := false

	serveCmd := &cobra.Command{
		Use:   "serve",
		Short: "Run the JetKVM emulator test server",
		RunE: func(cmd *cobra.Command, args []string) error {
			if cfg.AuthMode == "" {
				cfg.AuthMode = emulator.AuthModeNoPassword
			}
			if cfg.Password != "" {
				cfg.AuthMode = emulator.AuthModePassword
			}

			srv, err := emulator.NewServer(cfg)
			if err != nil {
				return err
			}

			ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
			defer stop()
			if logInputs {
				go func() {
					// Print every input the device receives as a JSON line,
					// for end-to-end tests of clients.
					seen := 0
					ticker := time.NewTicker(20 * time.Millisecond)
					defer ticker.Stop()
					enc := json.NewEncoder(os.Stdout)
					for {
						select {
						case <-ctx.Done():
							return
						case <-ticker.C:
							inputs := srv.Inputs()
							for _, in := range inputs[seen:] {
								_ = enc.Encode(in)
							}
							seen = len(inputs)
						}
					}
				}()
			}
			return srv.ListenAndServe(ctx)
		},
	}

	serveCmd.Flags().StringVar(&cfg.ListenAddr, "listen", "127.0.0.1:8080", "HTTP listen address")
	serveCmd.Flags().StringVar(&cfg.Password, "password", "", "Password for local auth mode; empty enables no-password mode")
	serveCmd.Flags().DurationVar(&cfg.Faults.RPCDelay, "rpc-delay", 0, "Delay every JSON-RPC response by this duration")
	serveCmd.Flags().StringVar(&cfg.Faults.DropRPCMethod, "drop-rpc-method", "", "Drop responses for a specific JSON-RPC method")
	serveCmd.Flags().DurationVar(&cfg.Faults.DisconnectAfter, "disconnect-after", 0, "Disconnect each WebRTC session after this duration")
	serveCmd.Flags().DurationVar(&cfg.Faults.HIDHandshakeDelay, "hid-handshake-delay", 0, "Delay the HID handshake response by this duration")
	serveCmd.Flags().StringVar(&cfg.Faults.InitialVideoState, "video-state", "ready", "Initial video input state event payload")
	serveCmd.Flags().IntVar(&cfg.Width, "width", 960, "Emulated video width")
	serveCmd.Flags().IntVar(&cfg.Height, "height", 540, "Emulated video height")
	serveCmd.Flags().IntVar(&cfg.FPS, "fps", 15, "Emulated video frame rate")
	serveCmd.Flags().IntVar(&cfg.GOP, "gop", 0, "Keyframe interval in frames (default: fps/2, like the device)")
	serveCmd.Flags().StringVar(&cfg.ReplayH264, "replay-h264", "", "Annex-B H.264 clip with AUDs to stream instead of the test pattern")
	serveCmd.Flags().StringVar(&cfg.ReplayH265, "replay-h265", "", "Annex-B H.265 clip with AUDs, streamed when a client offers H.265")
	serveCmd.Flags().Float64Var(&cfg.Netem.LossRate, "loss", 0, "Probability (0..1) of dropping each outgoing RTP packet")
	serveCmd.Flags().DurationVar(&cfg.Netem.Latency, "latency", 0, "One-way delay added to outgoing RTP packets")
	serveCmd.Flags().DurationVar(&cfg.Netem.HoldEvery, "hold-every", 0, "Stall outgoing RTP periodically (with --hold-for), releasing it in a burst")
	serveCmd.Flags().DurationVar(&cfg.Netem.HoldFor, "hold-for", 0, "How long each stall (--hold-every) holds outgoing RTP")
	serveCmd.Flags().Float64Var(&cfg.Netem.Rate, "rate", 0, "Link rate for outgoing RTP in bits per second (0: unlimited)")
	serveCmd.Flags().BoolVar(&cfg.KeyframeOnRequest, "keyframe-on-request", false, "Send a keyframe on RTCP PLI/FIR, like the patched firmware")
	serveCmd.Flags().BoolVar(&cfg.Desktop, "desktop", false, "Move the test pattern's box over a still screen of text: large keyframes, small frames between")
	serveCmd.Flags().DurationVar(&cfg.RebootDowntime, "reboot-downtime", 20*time.Second, "How long the device is unreachable after a reboot RPC")
	serveCmd.Flags().BoolVar(&cfg.TLS, "tls", false, "Serve https with a self-signed device CA, like the firmware's self-signed TLS mode")
	serveCmd.Flags().BoolVar(&cfg.EncoderPatch, "encoder-patch", false, "Answer get/setVideoEncoderParams like firmware with the desktop encoder patch")
	serveCmd.Flags().BoolVar(&cfg.RefreshRegions, "refresh-regions", false, "Like fork firmware D13: getFirmwareFeatures, autoRefresh and refreshRegions (implies --encoder-patch)")
	serveCmd.Flags().BoolVar(&cfg.StillScreen, "still-screen", false, "Show a still H.264 test picture that key presses type into")
	serveCmd.Flags().StringVar(&cfg.Tailscale, "tailscale", emulator.TailscaleRunning, "Tailscale state getTailscaleStatus reports: running, none or needs-login")
	serveCmd.Flags().IntVar(&cfg.Faults.UploadBytesPerSecond, "upload-rate", 0, "Throttle storage uploads to this many bytes per second")
	serveCmd.Flags().BoolVar(&logInputs, "log-inputs", false, "Print every received input as a JSON line on stdout")

	rootCmd := &cobra.Command{
		Use:   "emulator-serve",
		Short: "JetKVM emulator test harness",
		RunE: func(cmd *cobra.Command, args []string) error {
			return serveCmd.RunE(cmd, args)
		},
	}
	rootCmd.AddCommand(serveCmd)

	if err := rootCmd.Execute(); err != nil {
		log.Fatal(err)
	}
}
