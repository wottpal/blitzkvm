package hostlink

import (
	"bufio"
	"bytes"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"
)

//go:embed clipboard.js
var clipboardScript []byte

// MaxClipBytes bounds a clip's data (clipboard.js leaves out what doesn't
// fit, images first).
const MaxClipBytes = 8 << 20

// maxLine bounds one message from the Mac: a full clip, base64 in JSON.
const maxLine = MaxClipBytes*4/3 + 64<<10

// Clip is the clipboard's content: data by type (UTI), such as
// public.utf8-plain-text, public.rtf, public.html, public.png.
type Clip struct {
	Items map[string][]byte `json:"items"`
	// ID, when set, comes back once the Mac's clipboard has the clip
	// (StartClipboard's onApplied).
	ID string `json:"id,omitempty"`
}

// Size is the clip's data size in bytes.
func (c Clip) Size() int {
	n := 0
	for _, data := range c.Items {
		n += len(data)
	}
	return n
}

// message is one line of the protocol with clipboard.js.
type message struct {
	T     string            `json:"t"`
	Items map[string][]byte `json:"items,omitempty"`
	ID    string            `json:"id,omitempty"`
}

// silence ends a session that sent nothing (clipboard.js pings every 10 s).
const silence = 35 * time.Second

// ClipboardSession is the bridge running on the Mac.
type ClipboardSession struct {
	session *ssh.Session
	stdin   io.WriteCloser
	writeMu sync.Mutex
	done    chan struct{}
	err     error
	stderr  limitedWriter
}

// clipboardCommand starts clipboard.js twice under the shell (whatever the
// user's login shell is): "watch" in the background, "apply" on stdin.
func clipboardCommand() string {
	script := base64.StdEncoding.EncodeToString(clipboardScript)
	return `/bin/sh -c 'JS=$(printf %s ` + script + ` | /usr/bin/base64 -D) || exit 1; ` +
		`/usr/bin/osascript -l JavaScript -e "$JS" watch < /dev/null & W=$!; ` +
		`/usr/bin/osascript -l JavaScript -e "$JS" apply; kill $W 2> /dev/null'`
}

// StartClipboard runs the bridge on the Mac. onClip receives each change of
// the Mac's clipboard, onApplied the ID of each clip Set put on it (both
// from the session's reader goroutine). The session ends when the bridge
// exits, the Mac goes silent or Close is called; Done then closes and Err
// says why.
func StartClipboard(client *ssh.Client, onClip func(Clip), onApplied func(id string)) (*ClipboardSession, error) {
	session, err := client.NewSession()
	if err != nil {
		return nil, err
	}
	s := &ClipboardSession{session: session, done: make(chan struct{})}
	if s.stdin, err = session.StdinPipe(); err != nil {
		session.Close()
		return nil, err
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		session.Close()
		return nil, err
	}
	session.Stderr = &s.stderr
	if err := session.Start(clipboardCommand()); err != nil {
		session.Close()
		return nil, err
	}
	go s.read(stdout, onClip, onApplied)
	return s, nil
}

func (s *ClipboardSession) read(stdout io.Reader, onClip func(Clip), onApplied func(id string)) {
	activity := &activityReader{r: stdout}
	activity.touch()
	lines := make(chan []byte)
	readErr := make(chan error, 1)
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		reader := bufio.NewReaderSize(activity, 64<<10)
		for {
			line, err := readLine(reader)
			if err != nil {
				readErr <- err
				return
			}
			select {
			case lines <- line:
			case <-stop:
				return
			}
		}
	}()
	// Silence is measured in bytes, not messages: a large clip on a slow
	// link takes longer than the pings' interval to arrive.
	check := time.NewTicker(silence / 7)
	defer check.Stop()
	var err error
loop:
	for {
		select {
		case line := <-lines:
			var m message
			if json.Unmarshal(line, &m) != nil {
				continue // what the login shell's startup files print
			}
			switch {
			case m.T == "clip" && len(m.Items) > 0:
				onClip(Clip{Items: m.Items})
			case m.T == "applied" && m.ID != "" && onApplied != nil:
				onApplied(m.ID)
			}
		case err = <-readErr:
			break loop
		case <-check.C:
			if activity.idle() > silence {
				err = errors.New("the remote Mac stopped answering")
				break loop
			}
		}
	}
	s.session.Close()
	if errors.Is(err, io.EOF) {
		if msg := strings.TrimSpace(s.stderr.String()); msg != "" {
			err = fmt.Errorf("the clipboard bridge stopped: %s", msg)
		} else {
			err = errors.New("the connection to the remote Mac ended")
		}
	}
	s.err = err
	close(s.done)
}

// activityReader records when it last read anything.
type activityReader struct {
	r    io.Reader
	last atomic.Int64
}

func (a *activityReader) Read(p []byte) (int, error) {
	n, err := a.r.Read(p)
	if n > 0 {
		a.touch()
	}
	return n, err
}

func (a *activityReader) touch() { a.last.Store(time.Now().UnixNano()) }

func (a *activityReader) idle() time.Duration { return time.Since(time.Unix(0, a.last.Load())) }

// readLine reads up to a newline, failing on lines past maxLine.
func readLine(r *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		line = append(line, chunk...)
		if len(line) > maxLine {
			return nil, errors.New("message from the Mac too large")
		}
		if err == nil {
			return bytes.TrimSuffix(line, []byte{'\n'}), nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}

// Set puts clip on the Mac's clipboard.
func (s *ClipboardSession) Set(clip Clip) error {
	if clip.Size() > MaxClipBytes {
		return fmt.Errorf("clip too large: %d bytes", clip.Size())
	}
	line, err := json.Marshal(message{T: "clip", Items: clip.Items, ID: clip.ID})
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err = s.stdin.Write(append(line, '\n'))
	return err
}

// Done closes when the session ended.
func (s *ClipboardSession) Done() <-chan struct{} { return s.done }

// Err is why the session ended (after Done).
func (s *ClipboardSession) Err() error {
	<-s.done
	return s.err
}

// Close ends the session; the bridge on the Mac exits with it.
func (s *ClipboardSession) Close() {
	_ = s.stdin.Close()
	_ = s.session.Close()
}

// limitedWriter keeps the first 4 KiB written to it (the bridge's errors).
type limitedWriter struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (l *limitedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if room := 4<<10 - l.buf.Len(); room > 0 {
		l.buf.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

func (l *limitedWriter) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()
}
