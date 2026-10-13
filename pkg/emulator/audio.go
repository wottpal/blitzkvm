package emulator

import (
	"context"
	_ "embed"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"

	"github.com/wottpal/blitzkvm/pkg/logging"
)

// The device's audio: the target plays into the JetKVM's USB audio
// function, which the firmware sends as an audio track (audio.go,
// webrtc.go attachAudioTrack). Nothing is sent while the target plays
// nothing; with Config.AudioTone the target plays a 440 Hz tone for about a
// second, then nothing for a second, again and again.

const (
	audioFrame = 20 * time.Millisecond
	// audioSilence is the pause between tones.
	audioSilence = time.Second
)

// toneOpus is a second of the 440 Hz tone as Ogg Opus (48 kHz stereo,
// 20 ms frames), made with:
//
//	ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000:duration=1 -ac 2 \
//	  -c:a libopus -b:a 128k -frame_duration 20 -application audio \
//	  -map_metadata -1 -fflags +bitexact -flags:a +bitexact tone.opus
//
//go:embed tone.opus
var toneOpus []byte

// negotiateAudioCodec mirrors firmware: stock 0.5.9 sends G722 whenever the
// offer lists it, else PCMU (webrtc.go negotiateAudioCodec); fork D14
// (Config.OpusAudio) sends Opus where offered.
func (s *Server) negotiateAudioCodec(offerSDP string) string {
	upper := strings.ToUpper(offerSDP)
	switch {
	case s.cfg.OpusAudio && strings.Contains(upper, "OPUS/48000"):
		return webrtc.MimeTypeOpus
	case strings.Contains(upper, "G722/8000"):
		return webrtc.MimeTypeG722
	case strings.Contains(upper, "PCMU/8000"):
		return webrtc.MimeTypePCMU
	}
	return ""
}

// audioTrack is the track the device attaches to its answer: none while its
// audio is off or the offer has no codec it sends.
func (s *Server) audioTrack(offerSDP string) (webrtc.TrackLocal, error) {
	s.mu.Lock()
	enabled := s.state.AudioEnabled && s.state.USBDevices.Audio
	s.mu.Unlock()
	mime := s.negotiateAudioCodec(offerSDP)
	if !enabled || mime == "" {
		return nil, nil
	}
	if mime == webrtc.MimeTypeOpus {
		// Packetized here, like the fork: the marker bit starts each tone,
		// and the RTP timestamp keeps running through the silence.
		return webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: mime, ClockRate: 48000, Channels: 2}, "audio", "blitzkvm-emulator")
	}
	return webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: mime, ClockRate: 8000}, "audio", "blitzkvm-emulator")
}

// playTone sends Config.AudioTone's tone on track until ctx ends.
func (s *Server) playTone(ctx context.Context, track webrtc.TrackLocal) error {
	var frames [][]byte
	// write sends a frame of the tone-th tone at tick (20 ms since the start).
	var write func(tone, tick int, payload []byte) error
	switch t := track.(type) {
	case *webrtc.TrackLocalStaticRTP:
		packets, err := oggPackets(toneOpus)
		if err != nil {
			return err
		}
		frames = packets[2:] // after OpusHead and OpusTags
		var seq uint16
		lastTone := -1
		write = func(tone, tick int, payload []byte) error {
			seq++
			marker := tone != lastTone
			lastTone = tone
			return t.WriteRTP(&rtp.Packet{Header: rtp.Header{
				Version: 2, Marker: marker, SequenceNumber: seq, Timestamp: uint32(tick * 960),
			}, Payload: payload})
		}
	case *webrtc.TrackLocalStaticSample:
		if t.Codec().MimeType != webrtc.MimeTypePCMU {
			log := logging.Subsystem("emulator")
			log.Warn().Str("codec", t.Codec().MimeType).Msg("no tone for this audio codec")
			return nil
		}
		// Like stock firmware: pion's packetizer marks every packet, and the
		// RTP timestamp does not move while nothing is sent.
		frames = pcmuTone()
		write = func(_, _ int, payload []byte) error {
			return t.WriteSample(media.Sample{Data: payload, Duration: audioFrame})
		}
	default:
		return errors.New("unexpected audio track")
	}
	ticker := time.NewTicker(audioFrame)
	defer ticker.Stop()
	start := time.Now()
	period := len(frames) + int(audioSilence/audioFrame)
	for {
		select {
		case <-ctx.Done():
			return nil
		case now := <-ticker.C:
			tick := int(now.Sub(start) / audioFrame)
			i := tick % period
			if i >= len(frames) {
				continue // silence: no packets
			}
			if err := write(tick/period, tick, frames[i]); err != nil {
				return err
			}
		}
	}
}

// pcmuTone is a second of the 440 Hz tone in 20 ms G.711 µ-law frames,
// faded in and out over 5 ms.
func pcmuTone() [][]byte {
	const rate, n = 8000, 8000
	samples := make([]byte, n)
	for i := range samples {
		fade := min(1, float64(min(i, n-1-i))/(0.005*rate))
		samples[i] = linearToULaw(int16(0.25 * 32767 * fade * math.Sin(2*math.Pi*440*float64(i)/rate)))
	}
	var frames [][]byte
	for i := 0; i < n; i += rate / 50 {
		frames = append(frames, samples[i:i+rate/50])
	}
	return frames
}

// linearToULaw is the G.711 µ-law encoder.
func linearToULaw(sample int16) byte {
	const bias, clip = 0x84, 32635
	s := int(sample)
	sign := 0
	if s < 0 {
		s, sign = -s, 0x80
	}
	s = min(s, clip) + bias
	exponent := 7
	for mask := 0x4000; s&mask == 0 && exponent > 0; mask >>= 1 {
		exponent--
	}
	mantissa := (s >> (exponent + 3)) & 0x0f
	return ^byte(sign | exponent<<4 | mantissa)
}

// oggPackets returns the packets of a single-stream Ogg file.
func oggPackets(data []byte) ([][]byte, error) {
	var packets [][]byte
	var packet []byte
	for len(data) > 0 {
		if len(data) < 27 || string(data[:4]) != "OggS" {
			return nil, errors.New("not an Ogg page")
		}
		segments := int(data[26])
		if len(data) < 27+segments {
			return nil, errors.New("truncated Ogg page")
		}
		table, body := data[27:27+segments], data[27+segments:]
		for _, size := range table {
			if len(body) < int(size) {
				return nil, errors.New("truncated Ogg page")
			}
			packet = append(packet, body[:size]...)
			body = body[size:]
			if size < 255 {
				packets = append(packets, packet)
				packet = nil
			}
		}
		data = body
	}
	if len(packets) < 3 {
		return nil, errors.New("no Opus packets")
	}
	return packets, nil
}
