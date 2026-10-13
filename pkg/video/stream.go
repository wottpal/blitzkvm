package video

import (
	"context"
	"errors"
	"fmt"
	"image"
	"io"
	"os"
	"time"

	"github.com/pion/webrtc/v4"
)

// CodecFromMime maps a WebRTC MIME type to a Codec.
func CodecFromMime(mime string) (Codec, error) {
	switch mime {
	case webrtc.MimeTypeH264:
		return CodecH264, nil
	case webrtc.MimeTypeH265:
		return CodecH265, nil
	default:
		return 0, fmt.Errorf("unsupported codec %s", mime)
	}
}

// Receive reads RTP from track into an Assembler and a LinkEstimator until
// ctx ends or the track closes for good. Transient read errors (malformed
// packets) are skipped instead of ending the stream. rtt, if non-nil, is
// polled for the current round-trip estimate.
func Receive(ctx context.Context, track *webrtc.TrackRemote, asm *Assembler, link *LinkEstimator, rtt func() time.Duration) error {
	tickCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		ticker := time.NewTicker(10 * time.Millisecond)
		defer ticker.Stop()
		var lastRTTPoll time.Time
		for {
			select {
			case <-tickCtx.Done():
				return
			case now := <-ticker.C:
				if rtt != nil && now.Sub(lastRTTPoll) > 2*time.Second {
					lastRTTPoll = now
					asm.SetRTT(rtt())
				}
				asm.Tick(now)
			}
		}
	}()

	consecutiveErrors := 0
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		pkt, _, err := track.ReadRTP()
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrClosedPipe) || errors.Is(err, os.ErrDeadlineExceeded) || ctx.Err() != nil {
				return err
			}
			consecutiveErrors++
			if consecutiveErrors > 100 {
				return fmt.Errorf("video track: %w", err)
			}
			continue
		}
		consecutiveErrors = 0
		now := time.Now()
		link.Push(pkt, now)
		asm.Push(pkt, now)
	}
}

// Frame is a decoded picture.
type Frame struct {
	Image image.Image
	At    time.Time
}

// Sink consumes access units (a decoder, an IPC forwarder, ...).
type Sink interface {
	Push(AccessUnit)
	Close()
}

// FrameSource is implemented by sinks that keep the latest decoded picture.
type FrameSource interface {
	Latest() *Frame
	DecodedFrames() uint64
}

// SinkFunc adapts a function to a Sink.
type SinkFunc func(AccessUnit)

func (f SinkFunc) Push(au AccessUnit) { f(au) }
func (f SinkFunc) Close()             {}
