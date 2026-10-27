# Working on BigSigner OS with a device

The image is a Buildroot fork. The application is the sibling `bigsigner` repository, not this one. `docs/dev_workflow.md` is the human guide for flashing, SSH, and copying the app. This file is how an agent uses a running board with a person sitting in front of it.

## SSH

Use one persistent session. Do not open a new login for every command, and do not raise an approval prompt for each one.

```bash
docs/scripts/ssh-seedsigner.sh 'dmesg | grep bigsigner | tail'
```

The script keeps a master connection on `/tmp/seedsigner-ssh.sock` for 30 minutes. The host key is stored in `~/.ssh/seedsigner_known_hosts`, separate from the main known_hosts file. The root filesystem is in RAM, so that key changes on every reboot. When the key no longer matches, the script deletes that one file and connects again. Do not run `ssh-keygen -R` on the user's main known_hosts.

The dev-image root password is `seedsigner`, as written in `docs/dev_workflow.md`. The script uses the installed key when it works, and that password when the key is rejected.

`rsync` and `docs/scripts/rsync-to-seedsigner.sh` call `ssh` themselves. Point them at the same master socket, or they open a second login.

## Copying the app

The panel runs `/mnt/data/seedsigner/src/main.py` when that file exists, and `/opt/src` otherwise. The HDMI touch demo is `/opt/src` until the app is copied.

```bash
docs/scripts/rsync-to-seedsigner.sh --restart ~/private_workspace/bigsigner
```

`--restart` runs `seedsigner restart`. The old picture stays on the panel until the new process draws, which can take a few seconds. Do not rsync unless asked. Do not type a real seed into the device or the emulator.

The app repo often has a live emulator on port **8766**. Do not kill, restart, or bind that port.

## Sitting with the person at the panel

Tell them one action, in one short sentence, in the chat. Do not speak it with `say` or play a sound. Name the control as it is drawn: its words, its color, and where it sits.

The person replies in the chat with a short word such as "ok" after they have done it. That reply is what continues the work. A file watch or a background shell does not. Once the reply is sent, the agent is idle until the next chat message or a background job finishes, and a job left running often is not noticed promptly. Do not ask them to create a flag file and then end the turn waiting for it.

The screenshot tests and `artifacts/screenshots/<test name>/` are the map of the pages. Walk those flows on the device when checking speed. Frame times land in `dmesg` as `bigsigner: frame N ... ms` for the first frame and for any frame that takes 500 ms or more.

The camera on this board often has no sensor data. Leave it alone unless the person asks.
