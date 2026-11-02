#!/bin/sh
# Installs BlitzKVM's remote approvals on this Mac. Run as root: the BlitzKVM
# app uploads the files to a staging directory and runs this with sudo -S
# over SSH.
#
#   install.sh --identity STAGE    installs the binary and prints the target
#                                  identity ({"id":…,"key":…}) for the
#                                  genesis roster
#   install.sh [--no-sudo] STAGE   installs everything; --no-sudo leaves PAM
#                                  (sudo approvals) out
#
# STAGE holds blitzkvm-remote, pam_blitzkvm.so, roster.json (the genesis
# roster, owner-signed, naming this target), link.json and the two plists.
# Running it again updates an installation in place.
set -eu
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

SUPPORT="/Library/Application Support/BlitzKVM"
STATE="$SUPPORT/Remote"
BIN="$STATE/blitzkvm-remote"
LOGS="/Library/Logs/BlitzKVM"
PAM_DIR="/usr/local/lib/pam"
PAM_MODULE="$PAM_DIR/pam_blitzkvm.so"
PAM_LINE="auth       sufficient     $PAM_MODULE"
SUDO_LOCAL="/etc/pam.d/sudo_local"
DAEMON_LABEL="xyz.scio.blitzkvm.remote"
AGENT_LABEL="xyz.scio.blitzkvm.remote.agent"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="/Library/LaunchAgents/$AGENT_LABEL.plist"

die() {
	echo "install: $*" >&2
	exit 1
}

identity=0
pam=1
stage=""
for arg in "$@"; do
	case "$arg" in
	--identity) identity=1 ;;
	--no-sudo) pam=0 ;;
	-*) die "unknown option $arg" ;;
	*)
		[ -z "$stage" ] || die "one staging directory, please"
		stage=$arg
		;;
	esac
done
[ -n "$stage" ] && [ -d "$stage" ] || die "usage: install.sh [--identity] [--no-sudo] STAGE"
[ "$(id -u)" -eq 0 ] || die "run as root"

# put SRC DST MODE: copies a staged file into place, root-owned, atomically.
put() {
	[ -f "$1" ] || die "missing $1"
	tmp="$2.new.$$"
	cp "$1" "$tmp"
	chown root:wheel "$tmp"
	chmod "$3" "$tmp"
	mv -f "$tmp" "$2"
}

# rootdir DIR: DIR exists, belongs to root and only root may change it.
rootdir() {
	mkdir -p "$1"
	chown root:wheel "$1"
	chmod 0755 "$1"
}

rootdir "$SUPPORT"
rootdir "$STATE"
put "$stage/blitzkvm-remote" "$BIN" 0755

if [ "$identity" -eq 1 ]; then
	exec "$BIN" daemon --print-identity
fi

for f in roster.json link.json "$DAEMON_LABEL.plist" "$AGENT_LABEL.plist"; do
	[ -f "$stage/$f" ] || die "missing $stage/$f"
done
if [ "$pam" -eq 1 ]; then
	[ -f "$stage/pam_blitzkvm.so" ] || die "missing $stage/pam_blitzkvm.so"
	# sudo loads the module as root: nobody but root may be able to swap
	# it, so every directory above it must be root's (Homebrew on Intel
	# makes /usr/local the user's).
	for d in /usr/local /usr/local/lib; do
		if [ -e "$d" ]; then
			[ "$(stat -f %u "$d")" -eq 0 ] || die "$d isn't root's; install with --no-sudo"
			case "$(stat -f %Sp "$d")" in
			d????w???? | d???????w?) die "$d is writable by others; install with --no-sudo" ;;
			esac
		fi
	done
fi

# While things change, the PAM module steps aside and sudo asks for the
# password; a failed install leaves it that way until the next run.
: >"$STATE/maintenance"
failed() {
	[ $? -eq 0 ] || echo "install: failed; sudo asks for the password until the install succeeds" >&2
}
trap failed EXIT

put "$stage/link.json" "$STATE/link.json" 0644
"$BIN" daemon --install-roster "$stage/roster.json"

if [ "$pam" -eq 1 ]; then
	rootdir /usr/local/lib/pam
	# An unloadable module in sudo's stack would break sudo for everyone.
	file -b "$stage/pam_blitzkvm.so" | grep -q 'Mach-O 64-bit bundle' || die "pam_blitzkvm.so isn't a loadable module"
	put "$stage/pam_blitzkvm.so" "$PAM_MODULE" 0444
	if [ ! -f "$SUDO_LOCAL" ]; then
		if [ -f "$SUDO_LOCAL.template" ]; then
			cp "$SUDO_LOCAL.template" "$SUDO_LOCAL.new.$$"
		else
			echo "# sudo_local: local config file which survives system update and is included for sudo" >"$SUDO_LOCAL.new.$$"
		fi
		chown root:wheel "$SUDO_LOCAL.new.$$"
		chmod 0444 "$SUDO_LOCAL.new.$$"
		mv -f "$SUDO_LOCAL.new.$$" "$SUDO_LOCAL"
	fi
	if ! grep -q '^[[:space:]]*auth.*pam_blitzkvm\.so' "$SUDO_LOCAL"; then
		# First, so an approval comes before Touch ID or the password.
		{
			echo "$PAM_LINE"
			cat "$SUDO_LOCAL"
		} >"$SUDO_LOCAL.new.$$"
		chown root:wheel "$SUDO_LOCAL.new.$$"
		chmod 0444 "$SUDO_LOCAL.new.$$"
		mv -f "$SUDO_LOCAL.new.$$" "$SUDO_LOCAL"
	fi
	grep -q '^auth.*sudo_local' /etc/pam.d/sudo || echo "install: warning: /etc/pam.d/sudo doesn't include sudo_local" >&2
fi

rootdir "$LOGS"
# The daemon's log names who asked for what: root's alone.
touch "$LOGS/remote.log" && chmod 0600 "$LOGS/remote.log"
put "$stage/$DAEMON_LABEL.plist" "$DAEMON_PLIST" 0644
put "$stage/$AGENT_LABEL.plist" "$AGENT_PLIST" 0644
launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
launchctl bootstrap system "$DAEMON_PLIST"
uid=$(stat -f %u /dev/console)
if [ "$uid" -ne 0 ]; then
	launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
	launchctl bootstrap "gui/$uid" "$AGENT_PLIST" || echo "install: the agent starts at the next login" >&2
fi

rm -f "$STATE/maintenance"
echo "install: done"
