#!/bin/sh
#
# Copy one local file to seedsigner.local.
#
# Opens the shared master session from ssh-seedsigner.sh first
# (/tmp/seedsigner-ssh.sock), then rsyncs the file over that socket.
# Plain scp often fails against this board (OpenSSH client vs dropbear);
# rsync with the control path is what works. For a whole tree, use
# rsync-to-seedsigner.sh instead.
#
#   docs/scripts/copy-to-seedsigner.sh ./note.txt /mnt/microsd/
#   docs/scripts/copy-to-seedsigner.sh ./note.txt /mnt/microsd
#   docs/scripts/copy-to-seedsigner.sh ./tx.psbt /mnt/microsd/transaction.psbt
#
# A remote path that ends with / is a directory: the local basename is kept.
# A remote path that already exists as a directory on the device is the same.
# Any other remote path is the exact destination file (parent dirs are created).
#
# SEEDSIGNER_HOST and SEEDSIGNER_USER are the same ones ssh-seedsigner.sh uses.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSH="$HERE/ssh-seedsigner.sh"
HOST="${SEEDSIGNER_HOST:-seedsigner.local}"
USER="${SEEDSIGNER_USER:-root}"
SOCKET="${SEEDSIGNER_SOCKET:-/tmp/seedsigner-ssh.sock}"
KNOWN="${SEEDSIGNER_KNOWN_HOSTS:-$HOME/.ssh/seedsigner_known_hosts}"

usage() {
    cat <<'EOF'
Usage: docs/scripts/copy-to-seedsigner.sh <local-file> <remote-path>

Copy one file to seedsigner.local over the shared SSH session.
<remote-path> is a directory (keep the local name) or an exact file path.
EOF
}

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 1
fi

LOCAL=$1
REMOTE=$2

if [ ! -f "$LOCAL" ]; then
    echo "copy-to-seedsigner.sh: not a file: $LOCAL" >&2
    exit 1
fi

if [ -z "$REMOTE" ]; then
    echo "copy-to-seedsigner.sh: remote path is empty" >&2
    exit 1
fi

case "$REMOTE" in
    *\'*)
        echo "copy-to-seedsigner.sh: remote path must not contain a single quote" >&2
        exit 1
        ;;
esac

# Open or reuse the master session. Password, when needed, comes from
# ssh-seedsigner.sh's askpass helper — not from this terminal.
"$SSH" true

BASE=$(basename -- "$LOCAL")
case "$REMOTE" in
    */)
        DEST="${REMOTE}${BASE}"
        ;;
    *)
        if "$SSH" "test -d '$REMOTE'"; then
            DEST="${REMOTE%/}/${BASE}"
        else
            DEST=$REMOTE
        fi
        ;;
esac

PARENT=$(dirname -- "$DEST")
"$SSH" "mkdir -p '$PARENT'"

# /mnt/microsd is FAT: owner/group/mode cannot be set, so -a alone exits 23.
RSYNC_SSH="ssh -o ControlPath=$SOCKET -o UserKnownHostsFile=$KNOWN -o LogLevel=ERROR"
rsync -avz --no-owner --no-group --no-perms -e "$RSYNC_SSH" "$LOCAL" "$USER@$HOST:$DEST"

echo "Copied to $USER@$HOST:$DEST"
