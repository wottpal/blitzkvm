#!/bin/zsh
# fw.sh run [ENV=VALUE ...]   (re)start the patched build non-persistently with encoder env
# fw.sh log                   show the encoder log lines
# fw.sh stock                 reboot (back to the stock app)
# Needs JETKVM_HOST (device address) and JETKVM_SSH_KEY (the key set in
# Settings > Advanced > SSH Access, Developer Mode on). The patched binary
# must already be at /userdata/jetkvm/bin/jetkvm_app_debug(.new) (DEPLOY.md).
: ${JETKVM_HOST:?set JETKVM_HOST} ${JETKVM_SSH_KEY:?set JETKVM_SSH_KEY}
SSH=(ssh -i $JETKVM_SSH_KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=8 root@$JETKVM_HOST)
case $1 in
run)
  shift
  envs="$*"
  $SSH "sh -s" <<EOF
export LD_LIBRARY_PATH=/oem/usr/lib:\$LD_LIBRARY_PATH
killall jetkvm_app 2>/dev/null; killall jetkvm_app_debug 2>/dev/null
i=1; while [ \$i -le 15 ] && pgrep -f jetkvm_app >/dev/null; do sleep 1; i=\$((i+1)); done
cd /userdata/jetkvm/bin && { [ -f jetkvm_app_debug.new ] && mv -f jetkvm_app_debug.new jetkvm_app_debug; chmod +x jetkvm_app_debug; }
: > /tmp/jetkvm_app_debug.log
env $envs JETKVM_LOG_DEBUG=native sh -c "trap '' HUP; exec ./jetkvm_app_debug" >> /tmp/jetkvm_app_debug.log 2>&1 &
echo "started with: $envs"
EOF
  ;;
log)
  $SSH "grep -aE 'configured VENC|RequestIDR|requested keyframe|venc|error' /tmp/jetkvm_app_debug.log | tail -${2:-20}"
  ;;
stock)
  $SSH reboot
  ;;
esac
