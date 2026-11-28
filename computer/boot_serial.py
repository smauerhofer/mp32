#!/usr/bin/env python3
"""boot_serial.py: boot the mp32 computer over the serial port (pyserial).

  python boot_serial.py --port COM4                 load build/top.fs into the board,
                                                    wait for the boot loader to ask,
                                                    send build/os.img, show the rest
  python boot_serial.py --port COM4 --no-load       the same without loading the
                                                    bitstream (press S1 yourself)
  python boot_serial.py --port COM4 --send-only     only send the image, at once
  python boot_serial.py --port COM4 --terminal      after the image: a terminal, what
                                                    you type goes to the board
  python boot_serial.py --port COM4 --terminal-only only the terminal
  ... --terminal-only --send FILE                   in the terminal: whenever the board
                                                    says "send the image" (the loader,
                                                    FORTH's RECEIVE or INSTALL), FILE
                                                    goes to it

A FILE that is not an mp32 image (a font, say) is sent with an image header of its
own (load 0, entry 0), the way RECEIVE wants it; its size is rounded up to 4.

The port is opened before the bitstream goes in, so nothing the board says is missed.
Ctrl-C stops it (in the terminal: Ctrl-]). --port takes COM4 or /dev/ttyS3 (COMn is
/dev/ttyS(n-1)).

The terminal sends every key as you press it (Enter as CR) when it runs in a console:
cmd, PowerShell, Windows Terminal, or the MinGW shell through winpty (winpty python
boot_serial.py ...). In mintty without winpty Python cannot get single keys: then it
sends a line at a time, when you press Enter, and you see the line twice (yours, then
the board's echo).
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("boot_serial: pyserial is missing (python -m pip install pyserial)")

ASK = b"send the image"
QUIT_KEY = "\x1d"                       # Ctrl-]


def port_name(p):
    m = re.fullmatch(r"/dev/ttyS(\d+)", p)
    return "COM%d" % (int(m.group(1)) + 1) if m else p


def show(data):
    sys.stdout.write(data.decode("latin-1").replace("\r\n", "\n").replace("\r", "\n"))
    sys.stdout.flush()


def show_raw(data):
    # in the terminal: CR LF is a new line, BS SPACE BS rubs out (ACCEPT's echo)
    sys.stdout.write(data.decode("latin-1").replace("\r\n", "\n").replace("\r", ""))
    sys.stdout.flush()


def as_image(data):
    """data as an mp32 image: as it is if it is one, else with a header of its own."""
    if data[:4] == b"mp32":
        return data
    data = data + b"\0" * (-len(data) % 4)
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    head = [0x3233706D, 0, len(data), 0, sum(words) & 0xFFFFFFFF, 0, 0]
    head.append(-sum(head) & 0xFFFFFFFF)
    return struct.pack("<8I", *head) + data


def terminal(port, send_file=None):
    """What the board says on the screen, what you type to the board, until Ctrl-].
    send_file: sent whenever the board asks for an image."""
    stop = threading.Event()
    image = as_image(open(send_file, "rb").read()) if send_file else None
    lock = threading.Lock()

    def reader():
        seen = b""
        while not stop.is_set():
            try:
                data = port.read(256)
            except serial.SerialException:
                break
            if data:
                show_raw(data)
                seen = (seen + data)[-64:]
                if image is not None and ASK in seen:
                    seen = b""
                    time.sleep(0.05)
                    show_raw(port.read(256))
                    sys.stdout.write("[boot_serial: sending %s, %d bytes]\r\n"
                                     % (send_file, len(image)))
                    sys.stdout.flush()
                    with lock:
                        port.write(image)
                        port.flush()

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    def send(text):
        with lock:
            port.write(text.encode("latin-1", "replace"))

    try:
        if os.name == "nt" and sys.stdin.isatty():
            import msvcrt
            print("boot_serial: terminal, Ctrl-] to stop")
            while True:
                ch = msvcrt.getwch()
                if ch == QUIT_KEY:
                    break
                if ch in ("\x00", "\xe0"):      # an arrow, F1, ...: not for FORTH
                    msvcrt.getwch()
                    continue
                send(ch)
        elif os.name != "nt" and sys.stdin.isatty():
            import termios
            import tty
            print("boot_serial: terminal, Ctrl-] to stop")
            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            try:
                tty.setraw(fd)
                while True:
                    ch = os.read(fd, 1).decode("latin-1")
                    if ch == QUIT_KEY:
                        break
                    send("\r" if ch == "\n" else ch)
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
        else:
            print("boot_serial: terminal, a line at a time (no console: use winpty for "
                  "single keys); Ctrl-C to stop")
            for line in sys.stdin:
                send(line.rstrip("\r\n") + "\r")
    except KeyboardInterrupt:
        pass
    stop.set()
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="COM4")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--bitstream", default="build/top.fs")
    ap.add_argument("--image", default="build/os.img")
    ap.add_argument("--wait", type=float, default=30.0,
                    help="seconds to wait for the boot loader to ask (default 30)")
    ap.add_argument("--no-load", action="store_true", help="do not load the bitstream")
    ap.add_argument("--send-only", action="store_true", help="only send the image")
    ap.add_argument("--terminal", action="store_true",
                    help="after the image: a terminal (what you type goes to the board)")
    ap.add_argument("--terminal-only", action="store_true", help="only the terminal")
    ap.add_argument("--send", metavar="FILE",
                    help="in the terminal: FILE whenever the board asks for an image")
    a = ap.parse_args()

    port = serial.Serial(port_name(a.port), a.baud, timeout=0.05)
    port.reset_input_buffer()

    if a.terminal_only:
        terminal(port, a.send)
        return 0

    image = open(a.image, "rb").read()

    if a.send_only:
        port.write(image)
        port.flush()
        print("boot_serial: sent %s (%d bytes)" % (a.image, len(image)))
        return 0

    if not a.no_load:
        r = subprocess.run(["openFPGALoader", "-b", "tangnano20k", a.bitstream])
        if r.returncode != 0:
            return r.returncode

    # the loader's lines, until it asks for the image
    seen = b""
    end = time.time() + a.wait
    while ASK not in seen:
        if time.time() > end:
            print("\nboot_serial: the boot loader did not ask for the image within %g s"
                  % a.wait)
            print("             (an image in the flash at $400000? a card in the slot? "
                  "--port %s?)" % a.port)
            return 1
        data = port.read(256)
        if data:
            show(data)
            seen = (seen + data)[-256:]

    # the rest of that line, then the image
    time.sleep(0.05)
    show(port.read(256))
    print("boot_serial: sending %s (%d bytes)" % (a.image, len(image)))
    port.write(image)
    port.flush()

    if a.terminal:
        terminal(port, a.send)
        return 0

    # what the board says now
    print("boot_serial: Ctrl-C to stop")
    try:
        while True:
            data = port.read(256)
            if data:
                show(data)
    except KeyboardInterrupt:
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
