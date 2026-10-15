package hostlink

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"
)

// ErrHostKeyChanged: the Mac's SSH host key isn't the one pinned at setup.
var ErrHostKeyChanged = errors.New("the remote Mac's SSH identity changed")

// ErrKeyRefused: the Mac's SSH server doesn't accept this app's key (it was
// removed, or Remote Login doesn't allow the user).
var ErrKeyRefused = errors.New("the remote Mac doesn't accept this Mac's key")

// Login is how to log in to the Mac.
type Login struct {
	User string
	// PrivateKey is this app's key (OpenSSH PEM).
	PrivateKey []byte
	// HostKey pins the Mac's host key (authorized_keys format); empty
	// accepts any and reports it.
	HostKey string
}

// Connect runs the SSH handshake over conn (a stream to the Mac's SSH
// server) and returns the client and the Mac's host key, in authorized_keys
// format. It closes conn when ctx ends before the handshake does.
func Connect(ctx context.Context, conn net.Conn, login Login) (*ssh.Client, string, error) {
	signer, err := ssh.ParsePrivateKey(login.PrivateKey)
	if err != nil {
		return nil, "", fmt.Errorf("private key: %w", err)
	}
	algorithms := []string{ssh.KeyAlgoED25519, ssh.KeyAlgoECDSA256, ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256}
	var pinned ssh.PublicKey
	if login.HostKey != "" {
		if pinned, _, _, _, err = ssh.ParseAuthorizedKey([]byte(login.HostKey)); err != nil {
			return nil, "", fmt.Errorf("pinned host key: %w", err)
		}
		algorithms = hostKeyAlgorithms(pinned)
	}
	var hostKey string
	config := &ssh.ClientConfig{
		User: login.User,
		Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			hostKey = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))
			if pinned != nil && !bytes.Equal(key.Marshal(), pinned.Marshal()) {
				return ErrHostKeyChanged
			}
			return nil
		},
		HostKeyAlgorithms: algorithms,
	}

	type result struct {
		client *ssh.Client
		err    error
	}
	done := make(chan result, 1)
	go func() {
		c, chans, reqs, err := ssh.NewClientConn(conn, "remote-mac", config)
		if err != nil {
			done <- result{err: err}
			return
		}
		done <- result{client: ssh.NewClient(c, chans, reqs)}
	}()
	select {
	case r := <-done:
		if r.err != nil {
			_ = conn.Close()
			return nil, hostKey, classify(r.err)
		}
		return r.client, hostKey, nil
	case <-ctx.Done():
		_ = conn.Close()
		<-done
		return nil, hostKey, ctx.Err()
	}
}

// hostKeyAlgorithms are the algorithms that make the server present the
// pinned key.
func hostKeyAlgorithms(key ssh.PublicKey) []string {
	if key.Type() == ssh.KeyAlgoRSA {
		return []string{ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256}
	}
	return []string{key.Type()}
}

func classify(err error) error {
	switch {
	case errors.Is(err, ErrHostKeyChanged):
		return ErrHostKeyChanged
	case strings.Contains(err.Error(), "unable to authenticate"):
		return ErrKeyRefused
	}
	return err
}

// Run runs a command on the Mac and returns its output; stderr goes into
// the error when the command fails.
func Run(ctx context.Context, client *ssh.Client, command string) (string, error) {
	session, err := client.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()
	var stdout, stderr bytes.Buffer
	session.Stdout, session.Stderr = &stdout, &stderr
	done := make(chan error, 1)
	go func() { done <- session.Run(command) }()
	select {
	case err := <-done:
		if err != nil {
			if msg := strings.TrimSpace(stderr.String()); msg != "" {
				return stdout.String(), fmt.Errorf("%w: %s", err, msg)
			}
			return stdout.String(), err
		}
		return stdout.String(), nil
	case <-ctx.Done():
		_ = session.Signal(ssh.SIGTERM)
		return "", ctx.Err()
	}
}

// ActivityConn records when it last read anything, so that a large
// transfer on a slow link doesn't pass for a dead one.
type ActivityConn struct {
	net.Conn
	last atomic.Int64
}

func NewActivityConn(conn net.Conn) *ActivityConn {
	c := &ActivityConn{Conn: conn}
	c.last.Store(time.Now().UnixNano())
	return c
}

func (c *ActivityConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.last.Store(time.Now().UnixNano())
	}
	return n, err
}

// Idle is how long ago the last byte arrived.
func (c *ActivityConn) Idle() time.Duration { return time.Since(time.Unix(0, c.last.Load())) }

// KeepAlive asks the server for a reply every interval and closes the
// client once a request has gone unanswered for timeout while nothing at
// all arrived (a reply can queue behind a large transfer). It returns when
// the client closes.
func KeepAlive(client *ssh.Client, conn *ActivityConn, interval, timeout time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	closed := make(chan struct{})
	go func() {
		_ = client.Wait()
		close(closed)
	}()
	var pending chan error
	var sentAt time.Time
	for {
		select {
		case <-closed:
			return
		case err := <-pending:
			pending = nil
			if err != nil {
				_ = client.Close()
				return
			}
		case <-ticker.C:
			if pending == nil {
				pending = make(chan error, 1)
				sentAt = time.Now()
				go func(reply chan<- error) {
					_, _, err := client.SendRequest("keepalive@openssh.com", true, nil)
					reply <- err
				}(pending)
			} else if time.Since(sentAt) > timeout && conn.Idle() > timeout {
				_ = client.Close()
				return
			}
		}
	}
}
