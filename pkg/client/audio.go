package client

import (
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/wottpal/blitzkvm/pkg/logging"
)

// AudioCodec is the codec of the device's audio track.
type AudioCodec uint8

const (
	// AudioCodecOpus: fork firmware (D14), 48 kHz stereo, 20 ms frames, DTX.
	AudioCodecOpus AudioCodec = iota + 1
	// AudioCodecPCMU: stock firmware 0.5.9, 8 kHz mono G.711 µ-law, 20 ms.
	AudioCodecPCMU
)

func (c AudioCodec) String() string {
	switch c {
	case AudioCodecOpus:
		return "opus"
	case AudioCodecPCMU:
		return "pcmu"
	default:
		return "unknown"
	}
}

// AudioPacket is one RTP packet of the device's audio, as received.
type AudioPacket struct {
	Codec AudioCodec
	// Marker is the RTP marker bit: the fork sets it on the first packet
	// after silence; stock firmware sets it on every packet.
	Marker         bool
	SequenceNumber uint16
	Timestamp      uint32
	Payload        []byte
	ReceivedAt     time.Time
}

// audioCodecs are offered for the device's audio, preferred first. Stock
// firmware 0.5.9 answers G722 whenever the offer lists it, else PCMU
// (negotiateAudioCodec, webrtc.go); the fork answers Opus (D14). G722 stays
// out of the offer, so the app needs no decoder for it.
var audioCodecs = []webrtc.RTPCodecParameters{
	{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;stereo=1"}, PayloadType: 111},
	{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMU, ClockRate: 8000}, PayloadType: 0},
}

func audioCodecFromMime(mime string) (AudioCodec, bool) {
	switch {
	case strings.EqualFold(mime, webrtc.MimeTypeOpus):
		return AudioCodecOpus, true
	case strings.EqualFold(mime, webrtc.MimeTypePCMU):
		return AudioCodecPCMU, true
	}
	return 0, false
}

// receiveAudio forwards the device's audio packets until the track ends. It
// runs on its own goroutine, apart from the video's. The device sends
// nothing while the target plays nothing.
func (c *Client) receiveAudio(track *webrtc.TrackRemote) {
	log := logging.Subsystem("client")
	codec, ok := audioCodecFromMime(track.Codec().MimeType)
	if !ok {
		log.Warn().Str("codec", track.Codec().MimeType).Msg("audio track with a codec that was not offered; ignored")
		return
	}
	c.audioCodec.Store(uint32(codec))
	// At the level logged by default, like the video's resumes: once a
	// connection, with its first sound.
	log.Error().Str("codec", codec.String()).Uint32("clockRate", track.Codec().ClockRate).Uint16("channels", track.Codec().Channels).Msg("audio started")
	for errs := 0; errs <= 100; {
		pkt, _, err := track.ReadRTP()
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrClosedPipe) || errors.Is(err, os.ErrDeadlineExceeded) || c.ctx.Err() != nil {
				return
			}
			errs++ // a malformed packet; as many in a row end the audio
			continue
		}
		errs = 0
		c.audioPackets.Add(1)
		c.audioBytes.Add(uint64(len(pkt.Payload)))
		c.cfg.OnAudioPacket(AudioPacket{
			Codec:          codec,
			Marker:         pkt.Marker,
			SequenceNumber: pkt.SequenceNumber,
			Timestamp:      pkt.Timestamp,
			Payload:        pkt.Payload,
			ReceivedAt:     time.Now(),
		})
	}
}

// logAudioAnswer logs whether the device attached its audio: firmware
// answers the audio m-line inactive while its audio is off. Its track only
// shows up (OnTrack) with the first packet, once the target plays something.
func logAudioAnswer(answer webrtc.SessionDescription) {
	log := logging.Subsystem("client")
	parsed, err := answer.Unmarshal()
	if err != nil {
		return
	}
	for _, m := range parsed.MediaDescriptions {
		if m.MediaName.Media != "audio" {
			continue
		}
		_, sendonly := m.Attribute("sendonly")
		_, sendrecv := m.Attribute("sendrecv")
		log.Info().Bool("attached", sendonly || sendrecv).Msg("device audio")
		return
	}
}

// AudioOffered reports whether this client asked the device for audio.
func (c *Client) AudioOffered() bool { return c.cfg.OnAudioPacket != nil }

func (c *Client) GetAudioEnabled(ctx context.Context) (bool, error) {
	var config AudioConfig
	err := c.Call(ctx, "getAudioConfig", nil, &config)
	return config.Enabled, err
}

// SetAudioEnabled turns the device's audio on or off (persisted). Firmware
// keeps it off without an error while the USB audio function is off.
func (c *Client) SetAudioEnabled(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setAudioConfig", SetAudioConfigRequest{Params: AudioConfig{Enabled: enabled}}, nil)
}
