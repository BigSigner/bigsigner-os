#!/bin/sh
#
# Sync local seedsigner working tree to a pi0 dev device over ssh.
# The device runs the app from /mnt/data/seedsigner/src/main.py.
#
# Opens the shared master session from ssh-seedsigner.sh first
# (/tmp/seedsigner-ssh.sock), then points rsync at that socket so it
# does not open a second login or ask for the password again.
#
# Pass the application checkout. It is synced to root@seedsigner.local:/mnt/data/seedsigner/
#
#   docs/scripts/rsync-to-seedsigner.sh ~/private_workspace/bigsigner
#   docs/scripts/rsync-to-seedsigner.sh --restart ~/private_workspace/bigsigner
#
# For example, you can edit src/main.py in the tree you pass in, then sync it and restart.
# The panel keeps the previous picture until the new process draws, which can take a few seconds.
#
#   # edit hdmi-touch-demo/src/main.py
#   docs/scripts/rsync-to-seedsigner.sh --restart hdmi-touch-demo
# ---------------------------------------------------------------------------

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSH="$HERE/ssh-seedsigner.sh"
HOST="${SEEDSIGNER_HOST:-seedsigner.local}"
USER="${SEEDSIGNER_USER:-root}"
SOCKET="${SEEDSIGNER_SOCKET:-/tmp/seedsigner-ssh.sock}"
KNOWN="${SEEDSIGNER_KNOWN_HOSTS:-$HOME/.ssh/seedsigner_known_hosts}"
DEST_DIR="/mnt/data/seedsigner"

RESTART=""
SOURCE_DIR=""
for arg in "$@"; do
    case "$arg" in
        --restart)
            RESTART="1"
            ;;
        -*)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
        *)
            if [ -n "$SOURCE_DIR" ]; then
                echo "Unexpected argument: $arg" >&2
                exit 1
            fi
            SOURCE_DIR=$arg
            ;;
    esac
done

if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR" ]; then
    echo "Usage: rsync-to-seedsigner.sh [--restart] <source-dir>" >&2
    exit 1
fi

# Refuse a directory in the RAM rootfs when the SD card is absent or failed
# to mount. Otherwise a successful-looking sync disappears at the next boot.
# This also opens/reuses the shared SSH master session.
require_data_mount() {
    "$SSH" 'if ! awk '\''$1 == "/dev/mmcblk0p2" && $2 == "/mnt/data" && $3 == "ext4" && $4 ~ /(^|,)rw(,|$)/ { found = 1 } END { exit !found }'\'' /proc/mounts; then
        echo "SD-card data partition is not mounted read-write at /mnt/data. Insert the card and wait for it to mount before syncing." >&2
        exit 1
    fi'
}

require_data_mount

RSYNC_SSH="ssh -o ControlPath=$SOCKET -o UserKnownHostsFile=$KNOWN -o LogLevel=ERROR"

# mention about .git/ handling: the app's Version class parses a minimal set of .git/ files
# on-device (HEAD, config, refs) to display the current branch/tag/commit.
# Include just those; the trailing '.git/**' exclude drops everything else
# (objects, hooks, index, etc.). Order matters: rsync filters are first-match-wins.

sync_tree() {
rsync "$@" --delete \
    -e "$RSYNC_SSH" \
    --exclude 'rsync-to-seedsigner.sh' \
    --include '.git/' \
    --include '.git/HEAD' \
    --include '.git/config' \
    --include '.git/refs/' \
    --include '.git/refs/heads/***' \
    --include '.git/refs/tags/***' \
    --exclude '.git/**' \
    --exclude '.DS_Store' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude 'enclosures/' \
    --exclude 'venv/' \
    --exclude '.venv/' \
    --exclude 'seedsigner-screenshots/' \
    --exclude 'coverage_html_report/' \
    --exclude '.pytest_cache/' \
    --exclude 'build/' \
    --exclude 'dist/' \
    --exclude '*.egg-info/' \
    --exclude 'emulator-sdcard/' \
    --exclude '/artifacts/' \
    --exclude '/.cursor/' \
    --exclude '/pyproject.toml' \
    --exclude '/tests/' \
    --exclude '/scripts/' \
    --exclude '/docs/' \
    --exclude '/*.md' \
    "$SOURCE_DIR/" "$USER@$HOST:$DEST_DIR/"
}

# Compare contents as well as metadata, so a damaged file with an unchanged
# size and timestamp is repaired too.
sync_tree -avzc

# Finish SD-card writes before reporting success or starting the new app.
# A second mount check catches a card removed during the transfer.
"$SSH" sync
require_data_mount

# Do not let cached transfer data hide a card that fails to retain writes.
# Drop clean file pages before the second checksum comparison. This touches
# only files in the deployed checkout, leaving the rest of the OS cache alone.
"$SSH" 'python3 -' <<'PY'
import os
from pathlib import Path

for path in Path("/mnt/data/seedsigner").rglob("*"):
    if path.is_file() and not path.is_symlink():
        with path.open("rb") as handle:
            os.posix_fadvise(handle.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
PY

# Check the saved contents again without modifying them. A successful
# transfer alone does not detect corruption introduced while saving files.
VERIFY_CHANGES=$(sync_tree -rcni)
if [ -n "$VERIFY_CHANGES" ]; then
    echo "SD-card verification failed; the app has not been restarted:" >&2
    printf '%s\n' "$VERIFY_CHANGES" >&2
    exit 1
fi

if [ -n "$RESTART" ]; then
    "$SSH" "seedsigner restart"
fi
