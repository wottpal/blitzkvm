package video

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"

	openh264 "github.com/Azunyan1111/openh264-go"
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

// Receive reads RTP from track into an Assembler until ctx ends or the track
// closes for good. Transient read errors (malformed packets) are skipped
// instead of ending the stream. rtt, if non-nil, is polled for the current
// round-trip estimate.
func Receive(ctx context.Context, track *webrtc.TrackRemote, asm *Assembler, rtt func() time.Duration) error {
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
		asm.Push(pkt, time.Now())
	}
}

type Frame struct {
	Image image.Image
	At    time.Time
}

// DecodeStats describes the OpenH264 decoding sink.
type DecodeStats struct {
	Decoded      uint64
	DecodeErrors uint64
	Skipped      uint64
	LastError    string
}

// Stream decodes H.264 access units with OpenH264 on its own goroutine and
// keeps the latest picture. It is the sink used by the Ebiten test client; the
// native app decodes with VideoToolbox instead.
type Stream struct {
	mu      sync.RWMutex
	latest  *Frame
	lastErr error

	units     chan AccessUnit
	needKey   atomic.Bool
	decoded   atomic.Uint64
	errors    atomic.Uint64
	skipped   atomic.Uint64
	closeOnce sync.Once
	done      chan struct{}
	cancel    context.CancelFunc
}

// NewDecodingStream starts an OpenH264 decoder goroutine. Feed it with Push.
func NewDecodingStream(parent context.Context) (*Stream, error) {
	decoder, err := openh264.NewDecoder(bytes.NewReader(nil))
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(parent)
	s := &Stream{units: make(chan AccessUnit, 8), done: make(chan struct{}), cancel: cancel}
	go func() {
		defer close(s.done)
		defer decoder.Close()
		for {
			select {
			case <-ctx.Done():
				return
			case au := <-s.units:
				s.decode(decoder, au)
			}
		}
	}()
	return s, nil
}

func (s *Stream) decode(decoder *openh264.Decoder, au AccessUnit) {
	if s.needKey.Load() {
		if !au.Keyframe {
			s.skipped.Add(1)
			return
		}
		s.needKey.Store(false)
	}
	img, err := decoder.Decode(au.Data)
	if err == nil && img == nil {
		// OpenH264 holds Main/High-profile pictures for one call; the device
		// sends no B-frames, so flushing returns the picture immediately.
		img, err = decoder.Flush()
	}
	if err != nil {
		s.errors.Add(1)
		s.setError(err)
		return
	}
	if img == nil {
		return
	}
	s.decoded.Add(1)
	s.mu.Lock()
	s.latest = &Frame{Image: img, At: time.Now()}
	s.mu.Unlock()
}

// Push queues an access unit for decoding. If the decoder falls behind, the
// unit is dropped and decoding resumes at the next keyframe.
func (s *Stream) Push(au AccessUnit) {
	if au.Codec != CodecH264 {
		return
	}
	select {
	case s.units <- au:
	default:
		s.skipped.Add(1)
		s.needKey.Store(true)
	}
}

func (s *Stream) Latest() *Frame {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.latest
}

func (s *Stream) Err() error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.lastErr
}

func (s *Stream) Stats() DecodeStats {
	st := DecodeStats{Decoded: s.decoded.Load(), DecodeErrors: s.errors.Load(), Skipped: s.skipped.Load()}
	if err := s.Err(); err != nil {
		st.LastError = err.Error()
	}
	return st
}

func (s *Stream) setError(err error) {
	s.mu.Lock()
	s.lastErr = err
	s.mu.Unlock()
}

// Close stops the decoder and waits for it to finish.
func (s *Stream) Close() {
	s.closeOnce.Do(func() {
		s.cancel()
		<-s.done
	})
}
