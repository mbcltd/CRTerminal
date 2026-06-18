#!/usr/bin/env python3
# mouse1016.py — compare SGR cell coords (?1006) vs SGR-pixel coords (?1016).
#
# A manual probe for the SGR-pixels mouse encoding (DEC private mode 1016).
# Run it inside crterm, then click (and drag, holding a button) in the window:
#   - PIXELS mode reports device-pixel coordinates (x/y in the hundreds–
#     thousands; a drag changes them on sub-cell movement).
#   - CELLS mode reports column/row indices (small numbers; a drag within one
#     cell produces no new report).
# Press 'm' to toggle between the two modes, 'q' to quit.
#
# Notes:
#  - Uses ?1002 (button-event tracking) rather than ?1003 (any-event): the
#    latter reports every pointer move with no button held, which floods the
#    terminal.
#  - Disabling ?1016 resets the encoding to *legacy* (xterm-compatible), so to
#    select SGR cell coords we must re-assert ?1006h *after* ?1016l. The probe
#    also decodes legacy reports so an unexpected encoding can't jam it.
import sys, termios, tty, re, select

# SGR report: ESC [ < b ; x ; y (M|m).  Legacy report: ESC [ M <b> <x> <y>.
TOKEN = re.compile(rb'\x1b\[<(\d+);(\d+);(\d+)([mM])|\x1b\[M(.)(.)(.)', re.DOTALL)


def enable(pixel):
    # ?1002 = button-event tracking. Send the wanted encoding *last* so it wins:
    # ?1016h for pixels, else ?1006h for SGR cells (after clearing ?1016).
    if pixel:
        seq = "\x1b[?1002h\x1b[?1006h\x1b[?1016h"
    else:
        seq = "\x1b[?1002h\x1b[?1016l\x1b[?1006h"
    sys.stdout.write(seq)
    sys.stdout.flush()


def disable():
    sys.stdout.write("\x1b[?1016l\x1b[?1006l\x1b[?1002l")
    sys.stdout.flush()


def label(pixel):
    return "PIXELS (?1016)" if pixel else "CELLS (?1006)"


fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
pixel = True
last = None  # last printed report, to coalesce duplicate drag samples
try:
    tty.setraw(fd)
    enable(pixel)
    print(f"\r\nmode: {label(pixel)}  —  click & drag; 'm' toggle, 'q' quit\r")
    buf = b""
    while True:
        if not select.select([fd], [], [], None)[0]:
            continue
        chunk = sys.stdin.buffer.read1(64)
        if not chunk:  # EOF — stdin closed
            break
        buf += chunk

        # Pull complete mouse reports out of the stream; whatever is left is
        # keystroke input. (The SGR release terminator is a lowercase 'm', which
        # would otherwise collide with the 'm' toggle key — so reports must be
        # consumed before scanning for command keys.)
        keys = bytearray()
        end = 0
        for mo in TOKEN.finditer(buf):
            keys += buf[end:mo.start()]
            end = mo.end()
            if mo.group(4):  # SGR (cells or pixels, per current mode)
                b, x, y, fin = (int(mo.group(1)), int(mo.group(2)),
                                int(mo.group(3)), mo.group(4))
                enc = "PX" if pixel else "CELL"
                kind = "release" if fin == b'm' else ("drag" if b & 32 else "press")
            else:  # legacy ESC[M report — should not happen, but stay unjammed
                b = mo.group(5)[0] - 32
                x = mo.group(6)[0] - 32
                y = mo.group(7)[0] - 32
                enc, kind = "LEGACY", "?"
            sample = (enc, b, x, y, kind)
            if sample == last:  # drop identical consecutive reports
                continue
            last = sample
            print(f"\r{enc:6} b={b:<4} x={x:<5} y={y:<5} {kind}\r")

        # Hold back a trailing partial escape sequence for the next read.
        tail = buf[end:]
        esc = tail.find(b'\x1b')
        if esc == -1:
            keys += tail
            buf = b""
        else:
            keys += tail[:esc]
            buf = tail[esc:]
            if len(buf) > 64:  # safety: drop a stuck/unknown sequence
                buf = b""

        if b'q' in keys:
            break
        if b'm' in keys:
            pixel = not pixel
            last = None
            enable(pixel)
            print(f"\r\n--- mode: {label(pixel)} ---\r")
finally:
    disable()
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    print("\r\nbye\r")
