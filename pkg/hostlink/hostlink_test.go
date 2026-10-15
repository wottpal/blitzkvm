package hostlink

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

const deviceAddress = "fe80::4a:4bff:fe00:1"

func newKey(t *testing.T) (ssh.Signer, []byte, string) {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKey(private, "")
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	return signer, pem.EncodeToMemory(block), strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))
}

func TestAuthorizedKeyRestrictsTheKeyToTheLink(t *testing.T) {
	_, _, public := newKey(t)
	line, err := AuthorizedKey(public, deviceAddress, "BlitzKVM (Dennis' MacBook)")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(line, `from="fe80::4a:4bff:fe00:1%*",restrict ssh-ed25519 AAAA`) {
		t.Fatalf("line %q", line)
	}
	if !strings.HasSuffix(line, " BlitzKVM-Dennis-MacBook") {
		t.Fatalf("comment not sanitized: %q", line)
	}
	if _, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line)); err != nil {
		t.Fatalf("not a valid authorized_keys line: %v", err)
	}
	if _, err := AuthorizedKey(public, "192.168.1.5", ""); err == nil {
		t.Fatal("accepted a non-link-local address")
	}
}

var encodedScript = regexp.MustCompile(`initWithBase64EncodedStringOptions\("([A-Za-z0-9+/=]+)",0\)`)

func installScript(t *testing.T, command string) string {
	t.Helper()
	m := encodedScript.FindStringSubmatch(command)
	if m == nil {
		t.Fatalf("no script in %q", command)
	}
	script, err := base64.StdEncoding.DecodeString(m[1])
	if err != nil {
		t.Fatal(err)
	}
	return string(script)
}

func TestInstallCommandTypesTheSameOnEveryLayout(t *testing.T) {
	_, _, public := newKey(t)
	line, _ := AuthorizedKey(public, deviceAddress, "client")
	command, err := InstallCommand(line, deviceAddress)
	if err != nil {
		t.Fatal(err)
	}
	if !TypeSafe(command) {
		t.Fatalf("command has characters that type differently on a Mac: %q", command)
	}
	if !strings.HasSuffix(command, ",0),4).js)'") || !strings.HasPrefix(command, "osascript -l JavaScript -e '") {
		t.Fatalf("command %q", command)
	}
	script := installScript(t, command)
	for _, want := range []string{line, HostMAC, deviceAddress + "%$i", "4022"} {
		if !strings.Contains(script, want) {
			t.Errorf("script lacks %q:\n%s", want, script)
		}
	}
	if _, err := InstallCommand("x' ; rm -rf /", deviceAddress); err == nil {
		t.Fatal("accepted a line with a quote")
	}
}

// runScript runs a shell script with HOME in a temporary directory.
func runScript(t *testing.T, home, script string) {
	t.Helper()
	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.Env = append(os.Environ(), "HOME="+home)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("script failed: %v\n%s", err, out)
	}
}

func TestInstallAndUninstallKeepOtherKeys(t *testing.T) {
	_, _, public := newKey(t)
	line, _ := AuthorizedKey(public, deviceAddress, "client")
	command, _ := InstallCommand(line, deviceAddress)
	script := installScript(t, command)

	home := t.TempDir()
	keys := filepath.Join(home, ".ssh", "authorized_keys")
	if err := os.MkdirAll(filepath.Dir(keys), 0o700); err != nil {
		t.Fatal(err)
	}
	// An existing key without a trailing newline.
	other := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKey00 other"
	if err := os.WriteFile(keys, []byte(other), 0o600); err != nil {
		t.Fatal(err)
	}
	runScript(t, home, script)
	runScript(t, home, script) // twice: still one line
	data, _ := os.ReadFile(keys)
	if got := string(data); got != other+"\n"+line+"\n" {
		t.Fatalf("authorized_keys after install:\n%s", got)
	}

	uninstall, err := UninstallCommand(public)
	if err != nil {
		t.Fatal(err)
	}
	runScript(t, home, uninstall)
	data, _ = os.ReadFile(keys)
	if got := string(data); got != other+"\n" {
		t.Fatalf("authorized_keys after uninstall:\n%s", got)
	}
	if info, _ := os.Stat(keys); info.Mode().Perm() != 0o600 {
		t.Fatalf("permissions changed to %v", info.Mode().Perm())
	}
	runScript(t, home, uninstall) // nothing left to remove

	// No room for the result: the file stays as it was.
	if os.Getuid() != 0 {
		if err := os.Chmod(filepath.Dir(keys), 0o500); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("/bin/sh", "-c", uninstall)
		cmd.Env = append(os.Environ(), "HOME="+home)
		err := cmd.Run()
		_ = os.Chmod(filepath.Dir(keys), 0o700)
		if err == nil {
			t.Fatal("uninstall succeeded without a place for its result")
		}
		if data, _ := os.ReadFile(keys); string(data) != other+"\n" {
			t.Fatalf("a failed uninstall changed authorized_keys:\n%s", data)
		}
	}
	os.RemoveAll(filepath.Join(home, ".ssh"))
	runScript(t, home, uninstall) // no file at all
}

func TestInstallCreatesTheSSHFolder(t *testing.T) {
	_, _, public := newKey(t)
	line, _ := AuthorizedKey(public, deviceAddress, "")
	command, _ := InstallCommand(line, deviceAddress)
	home := t.TempDir()
	runScript(t, home, installScript(t, command))
	info, err := os.Stat(filepath.Join(home, ".ssh"))
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf(".ssh: %v %v", info, err)
	}
	data, _ := os.ReadFile(filepath.Join(home, ".ssh", "authorized_keys"))
	if string(data) != line+"\n" {
		t.Fatalf("authorized_keys:\n%s", data)
	}
}

// fakeMac is an SSH server whose exec runs a fake clipboard bridge: it
// greets, sends one clip, and records the clips it receives.
type fakeMac struct {
	hostKey  ssh.Signer
	userKey  ssh.PublicKey
	received chan Clip
	commands chan string
}

func newFakeMac(t *testing.T, userKey ssh.PublicKey) *fakeMac {
	t.Helper()
	host, _, _ := newKey(t)
	return &fakeMac{hostKey: host, userKey: userKey, received: make(chan Clip, 4), commands: make(chan string, 4)}
}

func (m *fakeMac) serve(t *testing.T, conn net.Conn) {
	config := &ssh.ServerConfig{
		PublicKeyCallback: func(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if meta.User() == "zoma" && string(key.Marshal()) == string(m.userKey.Marshal()) {
				return nil, nil
			}
			return nil, errors.New("no")
		},
	}
	config.AddHostKey(m.hostKey)
	_, chans, reqs, err := ssh.NewServerConn(conn, config)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for newChannel := range chans {
		channel, requests, err := newChannel.Accept()
		if err != nil {
			return
		}
		go func() {
			for req := range requests {
				if req.Type != "exec" {
					_ = req.Reply(false, nil)
					continue
				}
				var payload struct{ Command string }
				_ = ssh.Unmarshal(req.Payload, &payload)
				m.commands <- payload.Command
				_ = req.Reply(true, nil)
				go func() {
					_, _ = channel.Write([]byte(`{"t":"hello","v":1}` + "\n"))
					_, _ = channel.Write([]byte(`{"t":"clip","items":{"public.utf8-plain-text":"` +
						base64.StdEncoding.EncodeToString([]byte("from the Mac")) + `"}}` + "\n"))
					scanner := bufio.NewScanner(channel)
					scanner.Buffer(nil, maxLine)
					for scanner.Scan() {
						var msg message
						if json.Unmarshal(scanner.Bytes(), &msg) == nil {
							m.received <- Clip{Items: msg.Items}
						}
					}
					_ = channel.Close()
				}()
			}
		}()
	}
}

func connectPair(t *testing.T, mac *fakeMac, login Login) (*ssh.Client, string, error) {
	t.Helper()
	// A real socket: SSH deadlocks on net.Pipe, where both ends write their
	// version first and neither write returns until the other reads.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		if server, err := listener.Accept(); err == nil {
			mac.serve(t, server)
		}
	}()
	client, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return Connect(ctx, client, login)
}

func TestClipboardSessionBothWays(t *testing.T) {
	signer, private, _ := newKey(t)
	mac := newFakeMac(t, signer.PublicKey())
	client, hostKey, err := connectPair(t, mac, Login{User: "zoma", PrivateKey: private})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if !strings.HasPrefix(hostKey, "ssh-ed25519 ") {
		t.Fatalf("host key %q", hostKey)
	}

	fromMac := make(chan Clip, 1)
	session, err := StartClipboard(client, func(c Clip) { fromMac <- c })
	if err != nil {
		t.Fatal(err)
	}
	if cmd := <-mac.commands; !strings.HasPrefix(cmd, "/bin/sh -c 'JS=$(printf %s ") || !strings.Contains(cmd, " watch < /dev/null & ") {
		t.Fatalf("command %q", cmd)
	}
	select {
	case clip := <-fromMac:
		if string(clip.Items["public.utf8-plain-text"]) != "from the Mac" {
			t.Fatalf("clip %v", clip)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no clip from the Mac")
	}

	png := make([]byte, 200<<10)
	_, _ = rand.Read(png)
	if err := session.Set(Clip{Items: map[string][]byte{"public.utf8-plain-text": []byte("to the Mac"), "public.png": png}}); err != nil {
		t.Fatal(err)
	}
	select {
	case clip := <-mac.received:
		if string(clip.Items["public.utf8-plain-text"]) != "to the Mac" || string(clip.Items["public.png"]) != string(png) {
			t.Fatal("clip changed on the way")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the Mac got nothing")
	}

	if err := session.Set(Clip{Items: map[string][]byte{"public.png": make([]byte, MaxClipBytes+1)}}); err == nil {
		t.Fatal("a clip past the limit went out")
	}
	session.Close()
	select {
	case <-session.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("session didn't end")
	}
}

func TestConnectRefusesAChangedHostKey(t *testing.T) {
	signer, private, _ := newKey(t)
	mac := newFakeMac(t, signer.PublicKey())
	other, _, _ := newKey(t)
	pinned := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(other.PublicKey())))
	_, _, err := connectPair(t, mac, Login{User: "zoma", PrivateKey: private, HostKey: pinned})
	if !errors.Is(err, ErrHostKeyChanged) {
		t.Fatalf("err %v, want ErrHostKeyChanged", err)
	}

	right := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(mac.hostKey.PublicKey())))
	client, _, err := connectPair(t, mac, Login{User: "zoma", PrivateKey: private, HostKey: right})
	if err != nil {
		t.Fatalf("pinned key refused: %v", err)
	}
	client.Close()
}

func TestConnectReportsARefusedKey(t *testing.T) {
	signer, _, _ := newKey(t)
	mac := newFakeMac(t, signer.PublicKey())
	_, otherPrivate, _ := newKey(t)
	_, _, err := connectPair(t, mac, Login{User: "zoma", PrivateKey: otherPrivate})
	if !errors.Is(err, ErrKeyRefused) {
		t.Fatalf("err %v, want ErrKeyRefused", err)
	}
}
