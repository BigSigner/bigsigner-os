#!/bin/sh
#
# Send one command to the panel that is already running at seedsigner.local.
#
# The panel listens on a pipe in RAM, /tmp/bigsigner-rpc. Each line starts with
# a command word. This script forwards the command as it was typed. The panel
# checks it. addseed is one command: the words that follow are a BIP39 mnemonic.
# A 13th, 19th, or 25th word is the passphrase. A bad mnemonic is refused there.
# A seed that is already loaded is left as it is. tap, tapdown, tapmove,
# and tapup press the screen: tap x y is a down and an up, and the other
# three are those phases. This script does not stop or restart the panel.
# Secrets are not written to the SD card and are not printed.
#
#   docs/scripts/rpc.sh addseed abandon abandon abandon abandon abandon abandon \
#       abandon abandon abandon abandon abandon about
#   docs/scripts/rpc.sh addseed word word ... word secret
#
# The app on the device must already contain src/bigsigner/rpc.py, and the
# running panel must be a build that opens the pipe. Sync first, then start
# the panel once with `seedsigner start`. Do not use this on a device that
# holds real funds.
#
# BIGSIGNER_APP is the application checkout. The default is the sibling
# directory of this repository. SEEDSIGNER_HOST and SEEDSIGNER_USER are the
# same ones ssh-seedsigner.sh uses.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OS_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
APP=${BIGSIGNER_APP:-$(CDPATH= cd -- "$OS_ROOT/.." && pwd)/bigsigner}
SSH="$HERE/ssh-seedsigner.sh"

usage() {
    cat <<'EOF'
Usage: docs/scripts/rpc.sh COMMAND [ARG...]

Send one command to the running panel, as it was typed.
addseed takes the mnemonic words. A 13th, 19th, or 25th word is the passphrase.
The panel checks the line. A seed that is already loaded is left as it is.
The panel is not restarted.
EOF
}

if [ $# -eq 0 ]; then
    usage >&2
    exit 1
fi

COMMAND=$1

if [ ! -f "$APP/src/bigsigner/rpc.py" ]; then
    echo "rpc.sh: set BIGSIGNER_APP to the bigsigner checkout" >&2
    exit 1
fi

if [ -x "$APP/.venv/bin/python" ]; then
    PY="$APP/.venv/bin/python"
elif [ -x "$APP/.venv/bin/python3" ]; then
    PY="$APP/.venv/bin/python3"
else
    PY=python3
fi

line=$(PYTHONPATH="$APP/src" "$PY" -m bigsigner.rpc --format "$@")
b64=$(printf '%s' "$line" | base64 | tr -d '\n')

report=$("$SSH" "PAYLOAD='$b64' sh -s" <<'EOF'
set -eu
PIPE=/tmp/bigsigner-rpc

if [ -f /mnt/data/seedsigner/src/main.py ]; then
    APP_DIR=/mnt/data/seedsigner
    APP_SRC=/mnt/data/seedsigner/src
else
    APP_DIR=/opt
    APP_SRC=/opt/src
fi

if [ ! -f "$APP_SRC/bigsigner/rpc.py" ]; then
    echo "Sync the app first. $APP_SRC/bigsigner/rpc.py is missing." >&2
    exit 1
fi

PYTHON=/usr/bin/python3
for venv in "$APP_DIR/.venv" "$APP_DIR/venv"; do
    if [ -x "$venv/bin/python3" ]; then
        PYTHON=$venv/bin/python3
        break
    fi
done

report_count() {
    dmesg | grep -e 'bigsigner: seed ' -e 'bigsigner: command ' | wc -l
}

before=$(report_count)
if ! PYTHONPATH="$APP_SRC" "$PYTHON" -m bigsigner.rpc --pipe "$PIPE" --b64 "$PAYLOAD" 2>&1; then
    exit 1
fi
i=0
while [ "$i" -lt 200 ]; do
    after=$(report_count)
    if [ "$after" -gt "$before" ]; then
        dmesg | grep -e 'bigsigner: seed ' -e 'bigsigner: command ' | tail -n 1
        exit 0
    fi
    i=$((i + 1))
    sleep 0.1
done
echo "The panel did not report the command." >&2
exit 1
EOF
)

printf '%s\n' "$report"
case "$report" in
    *refused*)
        exit 1
        ;;
esac
