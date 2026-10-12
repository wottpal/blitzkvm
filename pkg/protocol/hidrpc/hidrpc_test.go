package hidrpc

import (
	"reflect"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	tests := []Message{
		Handshake{Version: Version},
		Keypress{Key: 4, Press: true},
		KeyboardReport{Modifier: 2, Keys: []byte{4, 5}},
		Pointer{X: 100, Y: 200, Buttons: 1},
		Mouse{DX: -2, DY: 4, Buttons: 1},
		Wheel{Y: -1, X: 1},
		KeyboardLEDState{Mask: 3},
		KeysDownState{Modifier: 2, Keys: []byte{4, 0, 0}},
		KeypressKeepAlive{},
	}

	for _, tt := range tests {
		data, err := tt.MarshalBinary()
		if err != nil {
			t.Fatalf("marshal %T: %v", tt, err)
		}
		got, err := Decode(data)
		if err != nil {
			t.Fatalf("decode %T: %v", tt, err)
		}
		if got.Type() != tt.Type() {
			t.Fatalf("message type mismatch for %T", tt)
		}
	}
}

func FuzzDecode(f *testing.F) {
	for _, seed := range [][]byte{
		{0x01, 0x01},
		{0x05, 0x04, 0x01},
		{0x03, 0, 0, 0, 1, 0, 0, 0, 2, 1},
		{0x07, 1, 0, 0, 0, 1, 2, 4, 0, 0, 0, 0, 0, 0, 20},
		{0x34, 1, 1},
		{0x09},
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		msg, err := Decode(data)
		if err != nil {
			return
		}
		// Every decodable message must survive an encode/decode round trip
		// (booleans decode leniently, so compare decoded values, not bytes).
		out, err := msg.MarshalBinary()
		if err != nil {
			t.Fatalf("marshal %T: %v", msg, err)
		}
		again, err := Decode(out)
		if err != nil {
			t.Fatalf("re-decode %T %x: %v", msg, out, err)
		}
		if !reflect.DeepEqual(again, msg) {
			t.Fatalf("round trip %T: %+v != %+v", msg, again, msg)
		}
	})
}
