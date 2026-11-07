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

# Open or reuse the master session. Password, when needed, comes from
# ssh-seedsigner.sh's askpass helper — not from this terminal.
"$SSH" true

RSYNC_SSH="ssh -o ControlPath=$SOCKET -o UserKnownHostsFile=$KNOWN -o LogLevel=ERROR"

# mention about .git/ handling: the app's Version class parses a minimal set of .git/ files
# on-device (HEAD, config, refs) to display the current branch/tag/commit.
# Include just those; the trailing '.git/**' exclude drops everything else
# (objects, hooks, index, etc.). Order matters: rsync filters are first-match-wins.

rsync -avz --delete \
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

if [ -n "$RESTART" ]; then
    "$SSH" "seedsigner restart"
fi
