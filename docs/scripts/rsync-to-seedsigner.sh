#!/bin/sh
#
# Sync local seedsigner working tree to a pi0 dev device over ssh.
# The device runs the app from /mnt/data/seedsigner/src/main.py.
#
# ---------------------------------------------------------------------------
# One-time connectivity setup (run on your Mac):
#
# 1. Add an SSH keypair to the pi0's authorized_keys (default root
#    password is "seedsigner"):
#      ssh root@seedsigner.local "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
#      cat ~/.ssh/id_ed25519.pub | ssh root@seedsigner.local \
#          "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
#
# 2. (Optional) Add a Host entry to ~/.ssh/config for a short "seedsigner"
#    alias and to silence host-key prompts across device re-flashes:
#      Host seedsigner seedsigner.local
#          HostName seedsigner.local
#          User root
#          StrictHostKeyChecking no
#          UserKnownHostsFile /dev/null
#          LogLevel ERROR
#
# 3. Test passwordless login:
#      ssh seedsigner.local
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

HOST="${SEEDSIGNER_HOST:-seedsigner.local}"
USER="${SEEDSIGNER_USER:-root}"
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

# mention about .git/ handling: the app's Version class parses a minimal set of .git/ files
# on-device (HEAD, config, refs) to display the current branch/tag/commit.
# Include just those; the trailing '.git/**' exclude drops everything else
# (objects, hooks, index, etc.). Order matters: rsync filters are first-match-wins.

rsync -avz --delete \
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
    ssh "$USER@$HOST" "seedsigner restart"
fi
