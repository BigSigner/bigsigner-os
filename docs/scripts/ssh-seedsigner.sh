#!/bin/sh
# One SSH session to the dev board. Later calls reuse it.
# The host key lives in ~/.ssh/seedsigner_known_hosts, not the main known_hosts.
# After a reboot the key changes: this script drops that file and connects again.

set -eu

HOST="${SEEDSIGNER_HOST:-seedsigner.local}"
USER="${SEEDSIGNER_USER:-root}"
SOCKET="${SEEDSIGNER_SOCKET:-/tmp/seedsigner-ssh.sock}"
KNOWN="${SEEDSIGNER_KNOWN_HOSTS:-$HOME/.ssh/seedsigner_known_hosts}"

mkdir -p "$HOME/.ssh"
touch "$KNOWN"
chmod 600 "$KNOWN"

askpass="$(mktemp)"
trap 'rm -f "$askpass"' EXIT
printf '%s\n' '#!/bin/sh' 'echo seedsigner' > "$askpass"
chmod 700 "$askpass"

common="
  -o UserKnownHostsFile=$KNOWN
  -o ControlPath=$SOCKET
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
"

start_master() {
  # shellcheck disable=SC2086
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-1}" \
    ssh -fN -M \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=publickey,password \
      -o NumberOfPasswordPrompts=1 \
      -o ControlPersist=30m \
      $common \
      "$USER@$HOST"
}

if ! ssh -O check $common "$USER@$HOST" >/dev/null 2>&1; then
  if ! start_master; then
    rm -f "$KNOWN"
    touch "$KNOWN"
    chmod 600 "$KNOWN"
    start_master
  fi
fi

exec ssh $common "$USER@$HOST" "$@"
