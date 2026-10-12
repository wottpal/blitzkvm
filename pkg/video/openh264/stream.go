// Package openh264 decodes H.264 access units in software. It is used by the
// Ebiten test client and tests; the native macOS app decodes with
// VideoToolbox and never links this package.
package openh264

import (
	"bytes"
	"context"
	"sync"
	"sync/atomic"
	"time"

	openh264 "github.com/Azunyan1111/openh264-go"

	"github.com/wottpal/blitzkvm/pkg/video"
)

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
	latest  *video.Frame
	lastErr error

	units     chan video.AccessUnit
	needKey   atomic.Bool
	decoded   atomic.Uint64
	errors    atomic.Uint64
	skipped   atomic.Uint64
	closeOnce sync.Once
	done      chan struct{}
	cancel    context.CancelFunc
}

// NewDecodingStream starts an OpenH264 decoder goroutine. Feed it with Push.
func NewStream(parent context.Context) (*Stream, error) {
	decoder, err := openh264.NewDecoder(bytes.NewReader(nil))
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(parent)
	s := &Stream{units: make(chan video.AccessUnit, 8), done: make(chan struct{}), cancel: cancel}
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

func (s *Stream) decode(decoder *openh264.Decoder, au video.AccessUnit) {
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
	s.latest = &video.Frame{Image: img, At: time.Now()}
	s.mu.Unlock()
}

// Push queues an access unit for decoding. If the decoder falls behind, the
// unit is dropped and decoding resumes at the next keyframe.
func (s *Stream) Push(au video.AccessUnit) {
	if au.Codec != video.CodecH264 {
		return
	}
	select {
	case s.units <- au:
	default:
		s.skipped.Add(1)
		s.needKey.Store(true)
	}
}

func (s *Stream) Latest() *video.Frame {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.latest
}

func (s *Stream) Err() error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.lastErr
}

// DecodedFrames implements video.FrameSource.
func (s *Stream) DecodedFrames() uint64 { return s.decoded.Load() }

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

// NewSink adapts NewStream to client.Config.NewVideoSink.
func NewSink(ctx context.Context, codec video.Codec) (video.Sink, error) {
	if codec != video.CodecH264 {
		return nil, errUnsupported(codec)
	}
	return NewStream(ctx)
}

type errUnsupported video.Codec

func (e errUnsupported) Error() string {
	return "openh264: unsupported codec " + video.Codec(e).String()
}
