#!/usr/bin/env python3
"""boot_serial.py: boot the mp32 computer over the serial port (pyserial).

  python boot_serial.py --port COM4                 load build/top.fs into the board,
                                                    wait for the boot loader to ask,
                                                    send build/os.img, show the rest
  python boot_serial.py --port COM4 --no-load       the same without loading the
                                                    bitstream (press S1 yourself)
  python boot_serial.py --port COM4 --send-only     only send the image, at once

The port is opened before the bitstream goes in, so nothing the board says is missed.
Ctrl-C stops it. --port takes COM4 or /dev/ttyS3 (COMn is /dev/ttyS(n-1)).
"""
import argparse
import re
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("boot_serial: pyserial is missing (python -m pip install pyserial)")

ASK = b"send the image"


def port_name(p):
    m = re.fullmatch(r"/dev/ttyS(\d+)", p)
    return "COM%d" % (int(m.group(1)) + 1) if m else p


def show(data):
    sys.stdout.write(data.decode("latin-1").replace("\r\n", "\n").replace("\r", "\n"))
    sys.stdout.flush()


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
    a = ap.parse_args()

    image = open(a.image, "rb").read()
    port = serial.Serial(port_name(a.port), a.baud, timeout=0.05)
    port.reset_input_buffer()

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
