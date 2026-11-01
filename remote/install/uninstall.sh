#!/bin/sh
# Removes BlitzKVM's remote approvals from this Mac, in the reverse order of
# install.sh. Run as root (the BlitzKVM app runs it with sudo -S over SSH).
# The target key goes too: a later install makes a new one.
set -eu
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

SUPPORT="/Library/Application Support/BlitzKVM"
STATE="$SUPPORT/Remote"
LOGS="/Library/Logs/BlitzKVM"
PAM_DIR="/usr/local/lib/pam"
PAM_MODULE="$PAM_DIR/pam_blitzkvm.so"
SUDO_LOCAL="/etc/pam.d/sudo_local"
DAEMON_LABEL="xyz.scio.blitzkvm.remote"
AGENT_LABEL="xyz.scio.blitzkvm.remote.agent"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="/Library/LaunchAgents/$AGENT_LABEL.plist"

[ "$(id -u)" -eq 0 ] || {
	echo "uninstall: run as root" >&2
	exit 1
}

# First: the PAM module steps aside while things go.
if [ -d "$STATE" ]; then
	: >"$STATE/maintenance"
fi

# sudo stops loading the module, then the module goes.
if [ -f "$SUDO_LOCAL" ] && grep -q 'pam_blitzkvm\.so' "$SUDO_LOCAL"; then
	tmp="$SUDO_LOCAL.new.$$"
	grep -v 'pam_blitzkvm\.so' "$SUDO_LOCAL" >"$tmp" || true
	chown root:wheel "$tmp"
	chmod 0444 "$tmp"
	mv -f "$tmp" "$SUDO_LOCAL"
fi
rm -f "$PAM_MODULE"
rmdir "$PAM_DIR" 2>/dev/null || true

uid=$(stat -f %u /dev/console)
if [ "$uid" -ne 0 ]; then
	launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
fi
launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
rm -f "$AGENT_PLIST" "$DAEMON_PLIST" /var/run/blitzkvm-remote.sock

# The binary, the target key, the roster, link.json and the flag.
rm -rf "/Library/Application Support/BlitzKVM/Remote"
rmdir "$SUPPORT" 2>/dev/null || true
rm -f "$LOGS/remote.log"
rmdir "$LOGS" 2>/dev/null || true
echo "uninstall: done"
