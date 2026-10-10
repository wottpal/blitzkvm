package emulator

import (
	"fmt"
	"strings"
)

// controlNames is the firmware's "names" normalisation (the default).
var controlNames = map[byte]string{
	0: "NUL", 1: "SOH", 2: "STX", 3: "ETX", 4: "EOT", 5: "ENQ", 6: "ACK", 7: "BEL",
	8: "BS", 11: "VT", 12: "FF", 14: "SO", 15: "SI", 16: "DLE", 17: "DC1", 18: "DC2",
	19: "DC3", 20: "DC4", 21: "NAK", 22: "SYN", 23: "ETB", 24: "CAN", 25: "EM", 26: "SUB",
	27: "ESC", 28: "FS", 29: "GS", 30: "RS", 31: "US", 127: "DEL",
}

// serialRX sends what the target printed the way firmware 0.5.9's console
// broker does with default settings (serial_console_helpers.go): ANSI CSI
// and OSC sequences pass through, other control characters become <NAME>,
// line endings are kept, and every new line starts with "RX: ".
func (sess *session) serialRX(data string) error {
	sess.mu.Lock()
	dc := sess.serial
	midLine := sess.serialMidLine
	var out strings.Builder
	in := []byte(data)
	for i := 0; i < len(in); {
		b := in[i]
		if !midLine {
			out.WriteString("RX: ")
			midLine = true
		}
		switch {
		case b == 0x1B && i+1 < len(in) && (in[i+1] == '[' || in[i+1] == ']'):
			j := i + 2
			for j < len(in) {
				c := in[j]
				j++
				if in[i+1] == '[' && c >= 0x40 && c <= 0x7E || in[i+1] == ']' && c == 0x07 {
					break
				}
			}
			out.Write(in[i:j])
			i = j
		case b == '\r' || b == '\n':
			out.WriteByte(b)
			if i+1 < len(in) && in[i+1] != b && (in[i+1] == '\r' || in[i+1] == '\n') {
				out.WriteByte(in[i+1])
				i++
			}
			i++
			midLine = false
		case b == '\t':
			out.WriteByte(b)
			i++
		case b < 0x20 || b == 0x7F:
			if name, ok := controlNames[b]; ok {
				out.WriteString("<" + name + ">")
			} else {
				out.WriteString(fmt.Sprintf("0x%02X", b))
			}
			i++
		default:
			out.WriteByte(b)
			i++
		}
	}
	sess.serialMidLine = midLine
	sess.mu.Unlock()
	if dc == nil {
		return nil
	}
	return dc.SendText(out.String())
}
