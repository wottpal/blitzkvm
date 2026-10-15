// Package hostlink syncs the clipboard with a remote Mac over the BlitzKVM
// firmware's host link (D17): a USB network link from the JetKVM to the Mac,
// through which this app reaches the Mac's own SSH server (Remote Login).
// Nothing is installed on the Mac but one key in ~/.ssh/authorized_keys,
// restricted to connections from the link; the clipboard bridge itself
// (clipboard.js) is sent with every session and runs under osascript.
package hostlink

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"

	"golang.org/x/crypto/ssh"
)

const (
	// HostMAC is the Mac's side of the link (the firmware's
	// NetworkHostMAC): the installer finds its interface by it.
	HostMAC = "02:4a:4b:00:00:02"
	// ReportPort takes the installer's report (user and computer name) on
	// the JetKVM's side of the link.
	ReportPort = 4022
	// Marker is the pasteboard type both ends add to what they put on the
	// pasteboard, so it isn't sent back.
	Marker = "com.blitzkvm.synced"
)

// AuthorizedKey is the line the installer adds to authorized_keys: the
// public key, usable only from the JetKVM's side of the link (a scoped
// link-local address, hence the wildcard) and without a terminal or
// forwarding.
func AuthorizedKey(publicKey, deviceAddress, comment string) (string, error) {
	key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(publicKey))
	if err != nil {
		return "", fmt.Errorf("public key: %w", err)
	}
	if !linkLocal.MatchString(deviceAddress) {
		return "", fmt.Errorf("not a link-local address: %q", deviceAddress)
	}
	line := fmt.Sprintf(`from="%s%%*",restrict %s %s`, deviceAddress, key.Type(), keyBody(key))
	if comment = sanitizeComment(comment); comment != "" {
		line += " " + comment
	}
	return line, nil
}

var linkLocal = regexp.MustCompile(`^fe80::[0-9a-f:]+$`)

func keyBody(key ssh.PublicKey) string { return base64.StdEncoding.EncodeToString(key.Marshal()) }

// sanitizeComment keeps the characters that survive the installer's quoting.
func sanitizeComment(comment string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', strings.ContainsRune("._@-", r):
			return r
		case r == ' ':
			return '-'
		}
		return -1
	}, comment)
}

// InstallCommand is what the app types into Terminal on the Mac: it adds
// authorizedKey (once) and reports the user and computer name to the
// JetKVM.
//
// The JetKVM types through its Windows-based layout tables, and on a Mac
// many characters sit elsewhere (~ | > < @ and brackets on most layouts,
// more on others). So the script travels base64-encoded inside an
// osascript one-liner of letters, digits and a little punctuation
// (TypeSafe) that InstallerLayouts type the same way on a Mac.
func InstallCommand(authorizedKey, deviceAddress string) (string, error) {
	if strings.ContainsAny(authorizedKey, "'\n") {
		return "", fmt.Errorf("unexpected characters in the key line")
	}
	key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(authorizedKey))
	if err != nil {
		return "", fmt.Errorf("key line: %w", err)
	}
	if !linkLocal.MatchString(deviceAddress) {
		return "", fmt.Errorf("not a link-local address: %q", deviceAddress)
	}
	script := strings.Join([]string{
		`umask 077`,
		`mkdir -p "$HOME/.ssh"`,
		`f="$HOME/.ssh/authorized_keys"`,
		`touch "$f"`,
		`if ! grep -qF '` + keyBody(key) + `' "$f"; then`,
		`  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi`,
		`  echo '` + authorizedKey + `' >> "$f"`,
		`fi`,
		`i=$(/sbin/ifconfig | /usr/bin/awk '/^[a-z]/{n=$1} /ether ` + HostMAC + `/{sub(":$","",n); print n; exit}')`,
		fmt.Sprintf(`if [ -n "$i" ]; then printf 'user=%%s\nname=%%s\n' "$(id -un)" "$(scutil --get ComputerName)" | /usr/bin/nc -w 3 "%s%%$i" %d; fi`,
			deviceAddress, ReportPort),
	}, "\n")
	encoded := base64.StdEncoding.EncodeToString([]byte(script))
	return `osascript -l JavaScript -e 'ObjC.import("stdlib");$.system($.NSString.alloc.initWithDataEncoding(` +
		`$.NSData.alloc.initWithBase64EncodedStringOptions("` + encoded + `",0),4).js)'`, nil
}

// InstallerLayouts are the JetKVM keyboard layouts whose tables type every
// TypeSafe character as a Mac with the matching input source does (checked
// on Macs: U.S. and German). Others differ: British puts " where the Mac
// has @, French moves - = +.
var InstallerLayouts = []string{"en-US", "de-DE"}

// TypeSafe reports whether s uses only the characters InstallCommand types.
func TypeSafe(s string) bool {
	for _, r := range s {
		ok := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune(` !"$%&/()=?+*#'-_.:,;`, r)
		if !ok {
			return false
		}
	}
	return true
}

// UninstallCommand removes publicKey's lines from authorized_keys, keeping
// the file (and its permissions) otherwise as it was. It leaves the file
// alone unless it could first write the result elsewhere.
func UninstallCommand(publicKey string) (string, error) {
	key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(publicKey))
	if err != nil {
		return "", fmt.Errorf("public key: %w", err)
	}
	return `f="$HOME/.ssh/authorized_keys"; [ -f "$f" ] || exit 0; t=$(mktemp "$f.XXXXXX") || exit 1; ` +
		`grep -vF '` + keyBody(key) + `' "$f" > "$t"; [ $? -le 1 ] || { rm -f "$t"; exit 1; }; ` +
		`cat "$t" > "$f"; s=$?; rm -f "$t"; exit $s`, nil
}
