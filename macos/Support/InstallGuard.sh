#!/bin/sh
# A boot guard for installing a build on a device you reach only over the
# network (see FORK.md, Install on a device; BlitzKVM's JetKVM Setup ships a
# copy and does the same). Copy it to /userdata/init.d/S99install-guard
# (executable), keep the running build as /userdata/jetkvm/jetkvm_app.backup,
# and arm it with `echo 0 > /userdata/install-guard.armed` before the reboot
# that installs the new build.
#
# While armed, each boot counts itself. The app has to answer on loopback
# within 15 checks 10 s apart (2.5-4 minutes), and again within 3 checks 5
# minutes later; then the count goes back to 0. When it does not, or after 3
# boots in a row without that (a crash loop the watchdog reboots), the backup
# becomes jetkvm_app.update (RkLunch.sh moves it into place at boot), the
# guard disarms itself and the device reboots. Its log is
# /userdata/install-guard.log; delete the marker to disarm it. SSH and
# Tailscale start independently of the app, so a build that misbehaves in
# other ways can still be replaced by hand.
armed=/userdata/install-guard.armed
good=/userdata/jetkvm/jetkvm_app.backup
log=/userdata/install-guard.log
status=http://127.0.0.1/device/status # answers without a login
[ "$1" = start ] || exit 0
[ -f "$armed" ] || exit 0
(
	rollback() {
		echo "$(date) rollback: $1" >>"$log"
		rm -f "$armed"
		if [ -f "$good" ] && cp "$good" /userdata/jetkvm/jetkvm_app.update; then
			sync
			reboot
		else
			echo "$(date) rollback failed: no $good" >>"$log"
		fi
	}
	# answers TRIES: whether the app answers within TRIES checks 10 s apart.
	answers() {
		t=0
		while [ "$t" -lt "$1" ]; do
			sleep 10
			t=$((t + 1))
			wget -q -T 5 -O /dev/null "$status" && return 0
		done
		return 1
	}
	n=$(cat "$armed" 2>/dev/null)
	case "$n" in
	'' | *[!0-9]*) n=0 ;;
	esac
	n=$((n + 1))
	echo "$n" >"$armed"
	sync
	if [ "$n" -gt 3 ]; then
		rollback "boot $n without a healthy app"
		exit 0
	fi
	if ! answers 15; then
		rollback "boot $n: app not answering"
		exit 0
	fi
	echo "$(date) boot $n: app answering" >>"$log"
	sleep 300
	if ! answers 3; then
		rollback "boot $n: app stopped answering"
		exit 0
	fi
	echo 0 >"$armed"
	sync
	echo "$(date) boot $n: app healthy" >>"$log"
) </dev/null >/dev/null 2>&1 &
