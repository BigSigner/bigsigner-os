# Building the HDMI touchscreen demo
Build a BigSigner OS dev image, flash it, and run `hdmi-touch-demo` on the device. The demo draws `logo.png` on the HDMI panel and prints the touch `x` and `y` underneath it.

This is a hardware testrun before the [full BigSigner build](building.md). It checks the Waveshare 4inch HDMI LCD (480×800 portrait) and the XPT2046 touch controller. It does not exercise the BigSigner application UI.

BigSigner OS is a fork of [SeedSigner OS](https://github.com/SeedSigner/seedsigner-os). The Docker build container name and several on-device names still use `seedsigner`. Built image files use the `bigsigner_os` prefix.

The demo runs on the Pi Zero family images, where HDMI and the touch controller are enabled:

| Board | Build script option |
| ----- | ------------------- |
| Raspberry Pi Zero / Zero W | `--pi0` |
| Raspberry Pi Zero 2 W | `--pi02w` |

<br/>

## 🔥🔥🔥🛠 Quickstart: HDMI touchscreen demo! 🛠🔥🔥🔥

### Hardware
* Raspberry Pi Zero, Zero W, or Zero 2 W
* Waveshare 4inch HDMI LCD (SKU 12030), used at its native 480×800 portrait resolution
* Mini HDMI cable from the Pi to the display
* The display's 26-pin header seated on pins 1–26 of the Pi, so the touch controller can use SPI
* A microSD card
* A data cable from your computer to the Pi's USB **data** port (the inner port labeled `USB` on a Zero, not the outer `PWR` port). The display's own micro-USB connector is power only.

### Install Dependencies
* Docker (choose one):
    * Desktop users: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
    * Or Linux command line: [Docker Engine](https://docs.docker.com/engine/install/#server)
* Windows PowerShell users may also need to [install `git`](https://git-scm.com/download/win). The git symlink and line-ending setup is in [Building a BigSigner SD card image](building.md#windows-prerequisites-powershell).

### Clone the bigsigner-os repo
In a terminal window:

```bash
# Copy the bigsigner-os repo to your local machine
git clone --recursive https://github.com/BigSigner/bigsigner-os.git

# Move into the repo directory
cd bigsigner-os
```

---

### Configure and begin the build
The `hdmi-touch-demo` service builds a dev image, does not clone the BigSigner application, and installs `main.py` and `logo.png` at `/opt/src`, which is the program the image already starts at boot. SSH over the Pi's USB data port is optional for this demo.

<details><summary>macOS / Linux instructions:</summary>
<p>


#### Configure environment variables
Force Docker to build on a container meant to run on amd64 in order to get an identical result, even if your actual cpu is different:

```bash
export DOCKER_DEFAULT_PLATFORM=linux/amd64
```

Select your board. Pi Zero and Zero W use `pi0`. Pi Zero 2 W uses `pi02w`.

```bash
export BOARD_TYPE=pi0
```

Initialize and update submodules (buildroot) from the bigsigner-os repo
```bash
git submodule init
git submodule update
```

#### Start the build!
`SS_ARGS` is passed to `build.sh`. The service always adds `--hdmi-touch-demo`, so leave that flag out. Omit `--dev` for a release image. With `SS_ARGS` unset, the container stays up and does not build, the same `--no-op` default as the normal builder. A plain `docker compose up` starts only the normal BigSigner OS builder.

```bash
SS_ARGS="--$BOARD_TYPE --dev" docker compose up hdmi-touch-demo --force-recreate --build
```
</p>
</details>


<details><summary>Windows PowerShell instructions:</summary>
<p>
*Note: We recommend running these steps in WSL2 (Windows Subsystem for Linux) instead of PowerShell so that you can just follow the macOS / Linux steps above.* Complete the [Windows prerequisites](building.md#windows-prerequisites-powershell) first.

#### Configure environment variables
```powershell
$env:DOCKER_DEFAULT_PLATFORM = 'linux/amd64'
$env:BOARD_TYPE = 'pi0'
```

Initialize and update submodules (buildroot) from the bigsigner-os repo
```powershell
git submodule init
git submodule update
```

#### Start the build!
`SS_ARGS` is passed to `build.sh`. The service always adds `--hdmi-touch-demo`, so leave that flag out. Omit `--dev` for a release image. With `SS_ARGS` unset, the container stays up and does not build, the same `--no-op` default as the normal builder. A plain `docker compose up` starts only the normal BigSigner OS builder.

```powershell
$env:SS_ARGS = "--$env:BOARD_TYPE --dev"
docker compose up hdmi-touch-demo --force-recreate --build
```

</p>
</details>
<br>

Building can take 25min to 2.5hrs+ depending on your cpu and will require 20-30 GB of disk space.

To build without Docker, on a Debian-based Linux host, follow [Building without Docker](without_docker.md) and run:

```bash
cd opt
./build.sh --pi0 --dev --hdmi-touch-demo
```


## Build Results
When the build completes you'll see:
```bash
hdmi-touch-demo-1  | /opt/buildroot
hdmi-touch-demo-1  | {image hash}  /opt/../images/bigsigner_os.hdmi-touch-demo.pi0-dev.<git-short>[-dirty].img
hdmi-touch-demo-1 exited with code 0
```

The completed image file will be in the `images` subdirectory.
```bash
cd images
ls -l

bigsigner_os.hdmi-touch-demo.pi0-dev.<git-short>[-dirty].img
```

A Pi Zero 2 W build is named `bigsigner_os.hdmi-touch-demo.pi02w-dev.<git-short>[-dirty].img`. The short hash is the bigsigner-os commit the image was built from. `-dirty` is added when that tree has uncommitted changes.


## Flash and boot

Write `images/bigsigner_os.hdmi-touch-demo.<board>-dev.<git-short>[-dirty].img` to a microSD card with Raspberry Pi Imager ("Use custom"), balenaEtcher, or `dd`. Put the card in the Pi, connect the HDMI display and the GPIO header, and power the Pi on.

The demo starts by itself. The logo appears on the panel, with `touch the screen` underneath it. A press replaces that line with the screen `x` and `y`.

SSH is optional. On a `--dev` image the Pi's USB **data** port is a network adapter: `ssh root@seedsigner.local` with password `seedsigner`. The demo also prints the framebuffer size, the touch device name, and each coordinate on that terminal.

If the axes are swapped, set `swapxy=1` on the `dtoverlay=ads7846,...` line in `opt/<board>/board/boot_config.txt` and `opt/<board>-dev/board/boot_config.txt`, then rebuild.
