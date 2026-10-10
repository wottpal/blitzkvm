package jsonrpc

import (
	"testing"
)

func TestDecodeMessage(t *testing.T) {
	t.Run("request", func(t *testing.T) {
		msg, err := DecodeMessage([]byte(`{"jsonrpc":"2.0","method":"ping","params":{},"id":"1"}`))
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := msg.(Request); !ok {
			t.Fatalf("expected Request, got %T", msg)
		}
	})

	t.Run("response", func(t *testing.T) {
		msg, err := DecodeMessage([]byte(`{"jsonrpc":"2.0","result":"pong","id":"1"}`))
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := msg.(Response); !ok {
			t.Fatalf("expected Response, got %T", msg)
		}
	})

	t.Run("event", func(t *testing.T) {
		msg, err := DecodeMessage([]byte(`{"jsonrpc":"2.0","method":"videoInputState","params":{"state":"ok"}}`))
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := msg.(Event); !ok {
			t.Fatalf("expected Event, got %T", msg)
		}
	})
}

func TestDecodeVoidResponse(t *testing.T) {
	// JetKVM omits "result" for handlers that only return an error.
	msg, err := DecodeMessage([]byte(`{"jsonrpc":"2.0","id":"rpc-7"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp, ok := msg.(Response)
	if !ok {
		t.Fatalf("expected Response, got %T", msg)
	}
	if resp.Error != nil || resp.Result != nil || resp.ID != "rpc-7" {
		t.Fatalf("unexpected void response: %+v", resp)
	}
}

func TestDecodeErrorResponseKeepsData(t *testing.T) {
	msg, err := DecodeMessage([]byte(`{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error","data":"mount failed: busy"},"id":3}`))
	if err != nil {
		t.Fatal(err)
	}
	resp := msg.(Response)
	if resp.Error == nil || resp.Error.Data != "mount failed: busy" {
		t.Fatalf("unexpected error response: %+v", resp.Error)
	}
}

func FuzzDecodeMessage(f *testing.F) {
	for _, seed := range []string{
		`{"jsonrpc":"2.0","method":"ping","params":{},"id":"1"}`,
		`{"jsonrpc":"2.0","result":"pong","id":"1"}`,
		`{"jsonrpc":"2.0","id":1}`,
		`{"jsonrpc":"2.0","method":"videoInputState","params":{"ready":true}}`,
		`{"jsonrpc":"2.0","error":{"code":-32601,"message":"x"},"id":2}`,
		`[]`, `null`, `{}`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = DecodeMessage(data)
	})
}
