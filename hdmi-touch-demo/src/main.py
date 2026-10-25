#!/usr/bin/env python3
"""Draw logo.png on the HDMI framebuffer and show touch coordinates.

Build and flash instructions: docs/hdmi_touch_demo.md

A --hdmi-touch-demo image starts this at boot. To run it by hand on the device:

    python3 main.py

Ctrl-C exits. The picture stays on screen.
"""

import fcntl
import glob
import os
import select
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

LOGO_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logo.png")
FB_DEV = "/dev/fb0"
TEXT_BAND = 80

# linux/input-event-codes.h
EV_ABS = 0x03
ABS_X = 0x00
ABS_Y = 0x01

# linux/fb.h — FBIOGET_VSCREENINFO is all fixed-width fields, so the
# beginning of the struct is the same on 32-bit and 64-bit.
FBIOGET_VSCREENINFO = 0x4600
# linux/input.h — EVIOCGABS(abs) == _IOR('E', 0x40 + abs, struct input_absinfo)
EVIOCGABS = lambda axis: 0x80184540 + axis

EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)


def read_text(path):
    with open(path, "r", encoding="ascii") as handle:
        return handle.read().strip()


def framebuffer_info(fb):
    """Return width, height, stride, bpp, and (red, green, blue) bit offsets."""
    var = bytearray(160)
    fcntl.ioctl(fb, FBIOGET_VSCREENINFO, var)
    xres, yres, _xvirt, _yvirt, _xoff, _yoff, bpp, _gray = struct.unpack_from("8I", var)

    def bitfield(index):
        offset, length, _msb_right = struct.unpack_from("3I", var, 32 + index * 12)
        return offset, length

    stride = int(read_text("/sys/class/graphics/fb0/stride"))
    # Trust the scanline length over bits_per_pixel when they disagree.
    if xres and stride % xres == 0:
        stride_bpp = (stride // xres) * 8
        if stride_bpp in (16, 32):
            bpp = stride_bpp
    return xres, yres, stride, bpp, (bitfield(0), bitfield(1), bitfield(2))


def silence_console():
    """Stop the kernel console from drawing over the framebuffer."""
    try:
        with open("/sys/class/graphics/fbcon/cursor_blink", "w", encoding="ascii") as handle:
            handle.write("0\n")
    except OSError:
        pass
    for path in glob.glob("/sys/class/vtconsole/vtcon*/bind"):
        try:
            with open(path, "w", encoding="ascii") as handle:
                handle.write("0\n")
        except OSError:
            pass
    try:
        tty = os.open("/dev/tty1", os.O_RDWR)
    except OSError:
        return
    try:
        fcntl.ioctl(tty, 0x4B3A, 1)  # KDSETMODE, KD_GRAPHICS
    except OSError:
        pass
    finally:
        os.close(tty)


def find_touch():
    """Return (event device path, name) for the ADS7846, if it is present."""
    for path in sorted(glob.glob("/dev/input/event*")):
        name_path = "/sys/class/input/{}/device/name".format(os.path.basename(path))
        try:
            name = read_text(name_path)
        except OSError:
            continue
        if "ads7846" in name.lower() or "touchscreen" in name.lower():
            return path, name
    return None, None


def axis_range(touch, axis):
    info = bytearray(24)
    fcntl.ioctl(touch, EVIOCGABS(axis), info)
    _value, minimum, maximum = struct.unpack_from("iii", info)
    return minimum, maximum


def scale(value, low, high, pixels):
    if high == low:
        return 0
    value = max(low, min(high, value))
    return int((value - low) * (pixels - 1) / (high - low))


def logo_canvas(width, height):
    """Black frame with the logo above the coordinate band."""
    canvas = Image.new("RGB", (width, height), (0, 0, 0))
    logo = Image.open(LOGO_PATH).convert("RGB")
    max_w = width - 16
    max_h = height - TEXT_BAND - 16
    logo.thumbnail((max_w, max_h), Image.Resampling.LANCZOS)
    canvas.paste(logo, ((width - logo.width) // 2, max(8, (max_h - logo.height) // 2)))
    return canvas


def with_label(base, point):
    """Copy the logo frame and draw the coordinate line under the image."""
    canvas = base.copy()
    width, height = canvas.size
    if point is None:
        label = "touch the screen"
    else:
        label = "x={}  y={}".format(point[0], point[1])

    font = ImageFont.load_default()
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    left, top, right, bottom = probe.textbbox((0, 0), label, font=font)
    text = Image.new("RGB", (right - left + 2, bottom - top + 2), (0, 0, 0))
    ImageDraw.Draw(text).text((1 - left, 1 - top), label, fill=(255, 255, 255), font=font)
    scale_factor = 4
    while text.width * scale_factor > width - 16 and scale_factor > 1:
        scale_factor -= 1
    text = text.resize((text.width * scale_factor, text.height * scale_factor), Image.Resampling.NEAREST)
    band_top = height - TEXT_BAND
    canvas.paste(text, ((width - text.width) // 2, band_top + (TEXT_BAND - text.height) // 2))
    return canvas


def canvas_to_fb(canvas, stride, bpp, channels):
    """Pack an RGB canvas into the framebuffer's pixel format."""
    def place(channel, offset, length):
        values = channel.astype(np.uint32)
        if length < 8:
            values >>= np.uint32(8 - length)
        return values << np.uint32(offset)

    (red_off, red_len), (green_off, green_len), (blue_off, blue_len) = channels
    rgb = np.asarray(canvas)
    pixels = place(rgb[:, :, 0], red_off, red_len)
    pixels |= place(rgb[:, :, 1], green_off, green_len)
    pixels |= place(rgb[:, :, 2], blue_off, blue_len)
    width, height = canvas.size
    if bpp == 16:
        row = pixels.astype(np.uint16).tobytes()
        row_bytes = width * 2
    elif bpp == 32:
        row = pixels.astype(np.uint32).tobytes()
        row_bytes = width * 4
    else:
        raise RuntimeError("unsupported framebuffer depth: {} bpp".format(bpp))

    # numpy packs a full row; the scanline may be longer than the visible pixels.
    if stride == row_bytes:
        return row
    frame = bytearray(stride * height)
    for y in range(height):
        start = y * row_bytes
        frame[y * stride:y * stride + row_bytes] = row[start:start + row_bytes]
    return bytes(frame)


def blit(fb, frame):
    os.lseek(fb, 0, os.SEEK_SET)
    os.write(fb, frame)


def main():
    if not os.path.exists(FB_DEV):
        print("no {} — HDMI framebuffer is not up".format(FB_DEV), file=sys.stderr)
        return 1
    if not os.path.exists(LOGO_PATH):
        print("missing {}".format(LOGO_PATH), file=sys.stderr)
        return 1

    fb = os.open(FB_DEV, os.O_RDWR)
    width, height, stride, bpp, channels = framebuffer_info(fb)
    print("framebuffer {}x{}  {} bpp  stride {}".format(width, height, bpp, stride))

    touch_path, touch_name = find_touch()
    touch = None
    x_range = (0, 1)
    y_range = (0, 1)
    if touch_path is None:
        print("no touchscreen event device; the picture will still be drawn")
    else:
        touch = os.open(touch_path, os.O_RDONLY | os.O_NONBLOCK)
        x_range = axis_range(touch, ABS_X)
        y_range = axis_range(touch, ABS_Y)
        print("touch {} ({})  x {}-{}  y {}-{}".format(
            touch_path, touch_name, x_range[0], x_range[1], y_range[0], y_range[1]))

    point = None
    raw = (None, None)
    silence_console()
    base = logo_canvas(width, height)
    blit(fb, canvas_to_fb(with_label(base, point), stride, bpp, channels))

    if touch is None:
        print("showing the logo only; Ctrl-C to exit")
        try:
            while True:
                select.select([], [], [], 3600)
        except KeyboardInterrupt:
            return 0

    print("touch the panel; Ctrl-C to exit")
    try:
        while True:
            readable, _, _ = select.select([touch], [], [], 1.0)
            if not readable:
                continue
            changed = False
            while True:
                try:
                    packet = os.read(touch, EVENT_SIZE * 64)
                except BlockingIOError:
                    break
                if not packet:
                    break
                for offset in range(0, len(packet) - EVENT_SIZE + 1, EVENT_SIZE):
                    _sec, _usec, ev_type, code, value = struct.unpack_from(EVENT_FORMAT, packet, offset)
                    if ev_type == EV_ABS and code == ABS_X:
                        raw = (value, raw[1])
                    elif ev_type == EV_ABS and code == ABS_Y:
                        raw = (raw[0], value)
                    else:
                        continue
                    if raw[0] is not None and raw[1] is not None:
                        point = (
                            scale(raw[0], x_range[0], x_range[1], width),
                            scale(raw[1], y_range[0], y_range[1], height),
                        )
                        changed = True
            if changed:
                print("x={}  y={}".format(point[0], point[1]))
                blit(fb, canvas_to_fb(with_label(base, point), stride, bpp, channels))
    except KeyboardInterrupt:
        return 0
    finally:
        os.close(touch)
        os.close(fb)


if __name__ == "__main__":
    sys.exit(main())
