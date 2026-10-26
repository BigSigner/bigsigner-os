# Developer workflow

BigSigner OS is a fork of [SeedSigner OS](https://github.com/SeedSigner/seedsigner-os). There are two overlapping kinds of "development" on BigSigner OS, and this doc covers both:

1. **Iterating on the OS build itself** (Buildroot, kernel, packages) — how to avoid a from-scratch rebuild every time. See [Iterating on the OS build](#iterating-on-the-os-build).
2. **Developing the BigSigner *application* on real hardware** using a `-dev` image — flash a networked, SSH-able image and edit / run / test the app right on the device. See [Developing the app on a `-dev` image](#developing-the-app-on-a--dev-image).

The *internals* of the developer images — what's added, how they're built, and the networking / pip / venv specifics — live in [dev_images.md](dev_images.md). This doc is the hands-on side: how you actually work.

To check HDMI and touch before developing the application, follow the [HDMI touchscreen demo](hdmi_touch_demo.md).

Commands, hostnames, paths, and script names below still use `seedsigner`. Those names come from the build configuration and the application, which have not been renamed yet. Built image files use the `bigsigner_os` prefix. The application repo cloned in this guide is [BigSigner](https://github.com/BigSigner/bigsigner).

---

## Iterating on the OS build

Each time the `docker compose up` command runs, a full build from scratch is performed. To get faster development cycles you'll want to keep the container around and drive the build steps yourself.

First make sure the submodules are in sync:
```bash
git submodule update --recursive
```

### Reuse the build container

Passing `--no-op` (the default) skips the build but keeps the container running in the background so you can shell in and work interactively. Start it *without* rebuilding the image:
```bash
SS_ARGS="--no-op" docker compose up -d --no-recreate
```

To start a fresh container environment instead, use `--force-recreate`:
```bash
SS_ARGS="--no-op" docker compose up -d --force-recreate --build
```

Open a shell inside the container:
```bash
docker exec -it seedsigner-os-build-images-1 bash
```

From there you can run the build script directly out of `/opt`:
```bash
./build.sh --pi0 --app-repo=https://github.com/BigSigner/bigsigner.git --app-branch=main --no-clean
```
or pin a specific commit:
```bash
./build.sh --pi0 --app-repo=https://github.com/BigSigner/bigsigner.git --app-commit-id=9c36f5c --no-clean
```

You can also use any of the Buildroot customization commands — `make menuconfig`, `make linux-menuconfig`, `make busybox-menuconfig` — from the `/output` directory (see [Customizing Buildroot](customize_buildroot.md)). Move an image you built manually with `make` into the shared volume with `mv images/bigsigner_os.img /images/`.

### "Disk full" troubleshooting

If your build fails with:
```
The partition table has been altered.
Syncing disks.
mkfs.fat 4.2 (2021-01-31)
Disk full
make[1]: *** [Makefile:815: target-post-image] Error 1
make: *** [Makefile:23: _all] Error 2
```

edit the `post-image-seedsigner.sh` script in your target board's `board/` subdir (e.g. `opt/pi0/board/`) and increase the disk-image size:
```
# Create disk image.
dd if=/dev/zero of=disk.img bs=1M count=26 #26 MB
```
Raise the `count` and re-run the build.

### Image location and naming

The `docker-compose.yml` mounts the repo's `images` directory as a container volume, so finished images land there on the host. They're named:

`bigsigner_os.<app_repo_branch>.<board_config>.os-commit-<os-short>[-dirty-<8>][-app-commit-<app-short>][-dirty].img`

For example a `pi0` built off the `0.5.2` branch at commit `842d99b` with app commit `9c36f5c` is `bigsigner_os.0.5.2.pi0.os-commit-842d99b-app-commit-9c36f5c.img`. Developer builds carry the board's `-dev` config in the name. Uncommitted changes in the bigsigner-os tree append `-dirty-` and the first 8 hex characters of the diff's SHA-256. A file under the app tree newer than `app-git-commit` appends a final `-dirty`.

---

## Developing the app on a `-dev` image

The `-dev` images run the same application, from the same Buildroot environment and the same libraries as the release images, with additions to make on-device development convenient: networking, an SSH server, a persistent data partition, editors, and `pip`. **They are not security-hardened — networking and SSH are enabled. Never use a dev image with real funds.**

Build one with:
```bash
./build.sh --<board> --dev          # <board> = pi0 | pi02w | pi2 | pi4
```
or via docker:
```bash
SS_ARGS="--<board> --dev" docker compose up --build
```
See [dev_images.md](dev_images.md) for what's inside the image and how it's configured.

### Quick start (macOS)

From a freshly built image, this takes you to running the test suite and your own code on the device.

#### 1. Flash the image to a microSD

Write `images/bigsigner_os.<branch>.<board>-dev.os-commit-<os-short>[-dirty-<8>][-app-commit-<app-short>][-dirty].img` to a microSD card with Raspberry Pi Imager ("Use custom"), balenaEtcher, or `dd`, then put the card in the BigSigner.

#### 2. Connect the device

The simplest path is the **USB relay** — the Pi appears to your Mac as a USB ethernet gadget over a single cable — but it needs a USB **OTG** port, which not every board exposes:

- **Pi Zero / Zero W (`pi0`) and Pi Zero 2 W (`pi02w`)** — two micro-USB ports. Connect to the **data** port (the inner one, labeled `USB`), **not** the outer `PWR` port. One cable both powers the board and talks to your Mac, so it boots as soon as it's plugged in.
- **Pi 4 (`pi4`)** — use the **USB-C** power port; it's OTG-capable and carries the gadget link over the same cable that powers the board.
- **Pi 2 Model B (`pi2`) / Pi 3 Model B** — their USB is behind an onboard hub with no exposed OTG port, so the USB relay doesn't come up. Instead use the board's **onboard Ethernet** (or a USB Wi-Fi / Ethernet adapter) and reach it over the network — skip to step 5 and `ssh root@seedsigner.local`.

#### 3. Share your Mac's internet over the USB link

*(USB-relay boards only — skip if you connected over Ethernet.)* The image appears to macOS as a USB ethernet gadget ("RNDIS/Ethernet Gadget"). Turn on Internet Sharing so the Mac hands it an IP address (and gives it internet for `git clone` / `pip`):

1. System Settings → General → **Sharing** → **Internet Sharing** (click the ⓘ).
2. **Share your connection from:** Wi-Fi.
3. **To computers using:** check the RNDIS/Ethernet Gadget (the USB interface).
4. Toggle **Internet Sharing** on (the indicator turns green).

The dev image already has the USB ethernet gadget configured, so nothing on the card needs editing.

#### 4. Add an SSH shortcut

Add this to `~/.ssh/config` on your Mac so you can just `ssh seedsigner` — always as `root`, with the host-key fingerprint check skipped (handy for a throwaway dev box):

```
Host seedsigner seedsigner.local
    HostName seedsigner.local
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
```

#### 5. Connect

```bash
ssh root@seedsigner.local
```

Password: `seedsigner`. Give the device 15–30s after plugging in to boot and bring `seedsigner.local` up. If the name doesn't resolve yet, wait a moment and retry, or find its address with `arp -a | grep bridge100` (USB relay) or from your router's DHCP leases. See [Finding the device / SSH](dev_images.md#finding-the-device--ssh) for how `.local` resolution works and the Wi-Fi / Ethernet paths.

#### 6. Clone the repo, set up the venv, and run the tests

On the device:

```bash
git clone https://github.com/BigSigner/bigsigner.git /mnt/data/seedsigner
cd /mnt/data/seedsigner
python3 -m venv venv
source venv/bin/activate
python3 -m pip install -e ".[dev]"
pytest
seedsigner restart
```

Notes:

- `/mnt/data` is the persistent partition, so the checkout and venv survive reboots.
- On this image `python3 -m venv` defaults to `--system-site-packages`, so the heavy native dependencies (Pillow, numpy, embit, pyzbar) come from the image and pip only installs the pure-Python dev/test tools into the venv. See [Installing Python packages](dev_images.md#installing-python-packages) for the details.
- `seedsigner restart` relaunches the app from your `/mnt/data/seedsigner` checkout (see [Controlling the app](#controlling-the-app)).

### Developing on the device

There are multiple ways to work on the BigSigner code with a dev image, and you can mix them freely — either way the app runs from `/mnt/data/seedsigner`:

- **A — Work directly on the device.** Clone the repo onto the device over the network and edit / commit / pull right there; `git`, editors (`vi`, `nano`), and the Python toolchain are all on the image. Good when you want a self-contained setup that doesn't depend on a host.
- **B — Edit on your Mac, sync to the device.** Keep your working tree and your editor/IDE on your Mac and push changes to the device with `rsync` whenever you want to test. Good when you prefer your host tooling.

In both cases `start.sh` runs `/mnt/data/seedsigner/src/main.py` when it exists (falling back to the embedded `/opt/src`), and uses a `venv`/`.venv` in the checkout if present — so once the code is under `/mnt/data/seedsigner`, the rest (controlling the app, tests, venvs) is identical.

#### Workflow A: clone on the device

```bash
git clone https://github.com/BigSigner/bigsigner.git /mnt/data/seedsigner
```

Then follow the venv/test setup in the [Quick start](#6-clone-the-repo-set-up-the-venv-and-run-the-tests). Edit in place on the device and `seedsigner restart` to pick up changes.

#### Workflow B: edit on your Mac, rsync to the device

Keep editing in your local checkout (e.g. `~/Source/bigsigner`) and push it to the device's `/mnt/data/seedsigner` over SSH. A ready-made helper lives at [`docs/scripts/rsync-to-seedsigner.sh`](scripts/rsync-to-seedsigner.sh). Pass it the checkout:

```bash
docs/scripts/rsync-to-seedsigner.sh ~/Source/bigsigner             # sync the working tree to the device
docs/scripts/rsync-to-seedsigner.sh --restart ~/Source/bigsigner   # ...and `seedsigner restart` afterward
```

It `rsync`s the checkout to `root@seedsigner.local:/mnt/data/seedsigner/` (override the target with the `SEEDSIGNER_HOST` / `SEEDSIGNER_USER` env vars), mirroring with `--delete` while excluding `venv/`, caches, screenshots, and the like. Its header comments walk through the one-time SSH-key setup so the sync is passwordless.

Most of `.git/` is excluded. First-time on the device you still need to create the venv — see the Quick start and [Running the tests](#running-the-tests).

### Controlling the app

The app is managed by a pidfile-tracked service, so you don't have to hunt down and `kill` python processes. From an SSH session or the console:

```bash
seedsigner status      # running (pid N) | stopped
seedsigner stop        # stop the app (frees the display)
seedsigner start       # start it (detached; survives SSH logout)
seedsigner restart     # stop + start -- pick up code changes
```

(`seedsigner` is a thin wrapper over `/etc/init.d/S02seedsigner`, which is what starts the app at boot.) So the edit loop is just: edit your tree under `/mnt/data/seedsigner`, then `seedsigner restart`. To run the app in the foreground instead (to watch its output/tracebacks live): `seedsigner stop`, then `cd /mnt/data/seedsigner/src && python3 main.py`.

### Running the tests

`pytest` is not in the image. The dev extra in `pyproject.toml` pins it. The suite's runtime libraries (Pillow, numpy, embit, pyzbar) are already in the image, and `python3 -m venv` includes the system site-packages by default here, so pip does not try to compile them:

```bash
cd /mnt/data/seedsigner
python3 -m venv venv                # defaults to --system-site-packages here
. venv/bin/activate
python3 -m pip install -e ".[dev]"  # the app, plus pytest 8.3.3
```

Sanity-check that the image's packages are visible in the venv, then run the suite from the repo root. It writes review screenshots under `artifacts/screenshots/`:

```bash
python3 -c "import PIL, numpy, embit; print('PIL', PIL.__version__)"
pytest
```

For the pip/venv mechanics behind all of this (why the venv defaults are flipped, installing extra packages, testing a newer version of a baked-in library), see [Installing Python packages](dev_images.md#installing-python-packages) in the dev image reference.
