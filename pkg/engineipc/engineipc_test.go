package engineipc

import (
	"bytes"
	"encoding/binary"
	"errors"
	"testing"
)

func TestFramesRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	w := NewWriter(&buf)
	hdr := AccessUnitHeader{Codec: 2, Flags: FlagKeyframe, RTPTimestamp: 12345, ReceivedUnixNano: 1000}
	if err := w.WriteFrame(TypeAccessUnit, append(hdr.Append(nil), 0, 0, 0, 1, 0x26)); err != nil {
		t.Fatal(err)
	}
	if err := w.WriteJSON(TypeCommand, Command{ID: 7, Cmd: "connect", BaseURL: "jetkvm.local"}); err != nil {
		t.Fatal(err)
	}

	r := NewReader(&buf)
	typ, payload, err := r.ReadFrame()
	if err != nil || typ != TypeAccessUnit {
		t.Fatalf("frame 1: %v %x", err, typ)
	}
	got, data, err := ParseAccessUnit(payload)
	if err != nil || got != hdr || !bytes.Equal(data, []byte{0, 0, 0, 1, 0x26}) {
		t.Fatalf("access unit: %+v %x %v", got, data, err)
	}
	typ, payload, err = r.ReadFrame()
	if err != nil || typ != TypeCommand || !bytes.Contains(payload, []byte(`"cmd":"connect"`)) {
		t.Fatalf("frame 2: %v %x %s", err, typ, payload)
	}
}

func TestReaderRejectsOversizedFrames(t *testing.T) {
	frame := binary.BigEndian.AppendUint32(nil, MaxFrameSize+1)
	_, _, err := NewReader(bytes.NewReader(frame)).ReadFrame()
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("want ErrFrameTooLarge, got %v", err)
	}
}

func FuzzReadFrame(f *testing.F) {
	f.Add([]byte{0, 0, 0, 3, 0x11, 4, 1})
	f.Add([]byte{0, 0, 0, 0})
	f.Fuzz(func(t *testing.T, data []byte) {
		r := NewReader(bytes.NewReader(data))
		for i := 0; i < 8; i++ {
			typ, payload, err := r.ReadFrame()
			if err != nil {
				return
			}
			if typ == TypeAccessUnit {
				_, _, _ = ParseAccessUnit(payload)
			}
		}
	})
}

func TestAudioHeaderRoundTrip(t *testing.T) {
	hdr := AudioHeader{Codec: 1, Flags: FlagMarker, SequenceNumber: 65535, RTPTimestamp: 0xdeadbeef, ReceivedUnixNano: -5}
	frame := append(hdr.Append(nil), 0xfc, 0xff)
	if len(frame) != AudioHeaderSize+2 {
		t.Fatalf("header is %d bytes, want %d", len(frame)-2, AudioHeaderSize)
	}
	got, payload, err := ParseAudio(frame)
	if err != nil || got != hdr || !bytes.Equal(payload, []byte{0xfc, 0xff}) {
		t.Fatalf("audio: %+v %x %v", got, payload, err)
	}
	if _, _, err := ParseAudio(frame[:AudioHeaderSize-1]); err == nil {
		t.Fatal("a short audio frame parsed")
	}
}
