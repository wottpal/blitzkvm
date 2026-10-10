// Package engineipc defines the wire protocol between the native macOS app
// and its jetkvm-engine helper (one helper process per device session).
//
// Every message is a frame: a 4-byte big-endian length (of type + payload),
// a 1-byte type, then the payload. Control messages carry JSON; the hot paths
// (video access units, keyboard and pointer input) are binary.
package engineipc

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

// MaxFrameSize bounds a single frame (a 4K keyframe stays far below it).
const MaxFrameSize = 16 << 20

// Message types, engine → app.
const (
	TypeEvent       byte = 0x01 // JSON Event
	TypeAccessUnit  byte = 0x02 // AccessUnitHeader + Annex-B bytes
	TypeRPCResult   byte = 0x03 // JSON RPCResult
	TypeCommandDone byte = 0x04 // JSON CommandResult
)

// Message types, app → engine.
const (
	TypeCommand    byte = 0x10 // JSON Command
	TypeKey        byte = 0x11 // hid u8, press u8
	TypeAbsPointer byte = 0x12 // x i32, y i32, buttons u8 (0..32767 range)
	TypeRelPointer byte = 0x13 // dx i16, dy i16, buttons u8
	TypeWheel      byte = 0x14 // y i8, x i8
)

// AccessUnitHeaderSize is the fixed header preceding Annex-B data.
const AccessUnitHeaderSize = 1 + 1 + 4 + 8

// Access unit flags.
const (
	FlagKeyframe byte = 1 << 0
)

// AccessUnitHeader precedes each video access unit.
type AccessUnitHeader struct {
	Codec        byte // 1 = H.264, 2 = H.265 (video.Codec values)
	Flags        byte
	RTPTimestamp uint32
	// ReceivedUnixNano is when the engine finished assembling the unit.
	ReceivedUnixNano int64
}

func (h AccessUnitHeader) Append(dst []byte) []byte {
	dst = append(dst, h.Codec, h.Flags)
	dst = binary.BigEndian.AppendUint32(dst, h.RTPTimestamp)
	return binary.BigEndian.AppendUint64(dst, uint64(h.ReceivedUnixNano))
}

func ParseAccessUnit(payload []byte) (AccessUnitHeader, []byte, error) {
	if len(payload) < AccessUnitHeaderSize {
		return AccessUnitHeader{}, nil, fmt.Errorf("access unit too short: %d", len(payload))
	}
	h := AccessUnitHeader{
		Codec:            payload[0],
		Flags:            payload[1],
		RTPTimestamp:     binary.BigEndian.Uint32(payload[2:6]),
		ReceivedUnixNano: int64(binary.BigEndian.Uint64(payload[6:14])),
	}
	return h, payload[AccessUnitHeaderSize:], nil
}

// Command is a JSON control message from the app.
type Command struct {
	ID int64 `json:"id,omitempty"`
	// Cmd is one of: connect, disconnect, reconnect, rpc, paste,
	// cancelPaste, releaseAll, ping, serialSend, setExtension (Text),
	// setSerialSettings (Params: session.SerialSettings), upload,
	// cancelUpload.
	Cmd      string `json:"cmd"`
	BaseURL  string `json:"baseURL,omitempty"`
	Password string `json:"password,omitempty"`
	DeviceID string `json:"deviceID,omitempty"`
	// CertSHA256 pins an https device's certificate authority (connect).
	CertSHA256 string          `json:"certSHA256,omitempty"`
	OfferH265  bool            `json:"offerH265,omitempty"`
	Method     string          `json:"method,omitempty"`
	Params     json.RawMessage `json:"params,omitempty"`
	Text       string          `json:"text,omitempty"`
	Delay      int             `json:"delay,omitempty"`
	// Path is a local file to upload to the device's storage (upload).
	Path string `json:"path,omitempty"`
	// Target is the ID of the upload command to cancel (cancelUpload).
	Target int64 `json:"target,omitempty"`
}

// Event is a JSON message from the engine. Type "snapshot" carries the
// session snapshot (without the serial scrollback); "stats" carries
// transport statistics; "serial" carries new serial console output in Text;
// "uploadProgress" carries Upload; "log" carries a diagnostic line.
type Event struct {
	Type     string          `json:"type"`
	Snapshot json.RawMessage `json:"snapshot,omitempty"`
	Stats    json.RawMessage `json:"stats,omitempty"`
	Message  string          `json:"message,omitempty"`
	Text     string          `json:"text,omitempty"`
	Upload   *UploadProgress `json:"upload,omitempty"`
}

// UploadProgress reports an upload command's progress; ID is the command's.
type UploadProgress struct {
	ID             int64   `json:"id"`
	Sent           int64   `json:"sent"`
	Total          int64   `json:"total"`
	BytesPerSecond float64 `json:"bytesPerSecond"`
}

// RPCResult answers an "rpc" command.
type RPCResult struct {
	ID     int64           `json:"id"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

// CommandResult answers other commands that carry an ID.
type CommandResult struct {
	ID    int64  `json:"id"`
	Error string `json:"error,omitempty"`
	// Invalid lists characters a paste could not type on the target layout.
	Invalid string `json:"invalid,omitempty"`
}

// Writer serialises frames; safe for concurrent use.
type Writer struct {
	mu  sync.Mutex
	w   *bufio.Writer
	buf []byte
}

func NewWriter(w io.Writer) *Writer {
	return &Writer{w: bufio.NewWriterSize(w, 256<<10)}
}

// WriteFrame writes one frame and flushes it.
func (w *Writer) WriteFrame(typ byte, payload []byte) error {
	if len(payload)+1 > MaxFrameSize {
		return fmt.Errorf("frame too large: %d", len(payload))
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = binary.BigEndian.AppendUint32(w.buf[:0], uint32(len(payload)+1))
	w.buf = append(w.buf, typ)
	if _, err := w.w.Write(w.buf); err != nil {
		return err
	}
	if _, err := w.w.Write(payload); err != nil {
		return err
	}
	return w.w.Flush()
}

// WriteJSON writes v as a JSON frame of the given type.
func (w *Writer) WriteJSON(typ byte, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return w.WriteFrame(typ, data)
}

// ErrFrameTooLarge is returned for frames exceeding MaxFrameSize.
var ErrFrameTooLarge = errors.New("engineipc: frame too large")

// Reader parses frames.
type Reader struct {
	r   *bufio.Reader
	hdr [4]byte
}

func NewReader(r io.Reader) *Reader {
	return &Reader{r: bufio.NewReaderSize(r, 64<<10)}
}

// ReadFrame returns the next frame. The payload is a fresh slice.
func (r *Reader) ReadFrame() (byte, []byte, error) {
	if _, err := io.ReadFull(r.r, r.hdr[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(r.hdr[:])
	if n == 0 {
		return 0, nil, fmt.Errorf("engineipc: empty frame")
	}
	if n > MaxFrameSize {
		return 0, nil, ErrFrameTooLarge
	}
	frame := make([]byte, n)
	if _, err := io.ReadFull(r.r, frame); err != nil {
		return 0, nil, err
	}
	return frame[0], frame[1:], nil
}
