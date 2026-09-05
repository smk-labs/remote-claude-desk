#!/usr/bin/env python3
"""Clipboard agent. Runs on the server, driven by desk-clip over the SSH master.

Reads "SET <b64>" lines on stdin, owns the X CLIPBOARD selection through xclip,
and prints "CLIP <b64>" (text) or "CLIPIMG <b64>" (a png) when something else
in the session copies. It never
echoes back a value it set itself, which is what stops the ping-pong.

argv[1] is the X display to attach to.
"""
import base64, os, subprocess, sys, threading, time
DISP = sys.argv[1]
ENV  = dict(os.environ, DISPLAY=DISP, XAUTHORITY=os.path.expanduser("~/.Xauthority"))
owner = [None]      # the live `xclip -i` process
mine  = [None]      # the value we last SET, cleared the first time the poll
                    # sees it. ONE shot, not a history: a remembered list meant
                    # that when the session copied text the Mac had held
                    # earlier, it was mistaken for our own echo and never
                    # reached the Mac at all.
quiet = [0.0]       # ignore polls for a moment after a SET, so a read that
                    # lands before xclip owns the selection cannot report the
                    # previous value as if someone had just copied it.

def set_clip(data, target="UTF8_STRING"):
    if owner[0] and owner[0].poll() is None:
        owner[0].terminate()
        try: owner[0].wait(timeout=2)
        except Exception: owner[0].kill()
    mine[0]  = data
    quiet[0] = time.time() + 0.8
    # image/png for a picture, UTF8_STRING for text. One owner either way: the
    # selection can only have one, so an image replaces the text and vice versa,
    # exactly as a copy on the Mac does.
    owner[0] = subprocess.Popen(["xclip", "-selection", "clipboard", "-t", target, "-i"],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, env=ENV)
    owner[0].stdin.write(data); owner[0].stdin.close()

def reader():
    for line in sys.stdin:
        line = line.strip()
        if line.startswith("SET "):
            try: set_clip(base64.b64decode(line[4:]))
            except Exception as e: sys.stderr.write("agent set: %r\n" % (e,))
        elif line.startswith("SETIMG "):
            # The picture arrives as png and is offered as image/png, which is
            # the target Chromium and Qt actually read. xrdp's own clipboard
            # offered image/bmp and nothing else, which is why this does not go
            # through the RDP channel.
            try: set_clip(base64.b64decode(line[7:]), "image/png")
            except Exception as e: sys.stderr.write("agent setimg: %r\n" % (e,))
        elif line == "BYE":
            os._exit(0)
    os._exit(0)     # stdin closed: the Mac side is gone, so go with it rather
                    # than sitting on the X selection forever.

threading.Thread(target=reader, daemon=True).start()
sys.stdout.write("READY\n"); sys.stdout.flush()
last = None
while True:
    time.sleep(0.4)
    if time.time() < quiet[0]:
        continue
    # Ask what is on offer before asking for it. The selection holds one thing
    # at a time, so a picture copied in the session replaces the text, and
    # reading UTF8_STRING from a picture returns nothing at all: this used to
    # poll only text, and an image copied on the remote side simply never
    # reached the Mac.
    try:
        t = subprocess.run(["xclip", "-selection", "clipboard", "-t", "TARGETS", "-o"], env=ENV,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        targets = t.stdout.decode("utf-8", "replace").split() if t.returncode == 0 else []
    except Exception:
        continue

    kind = "image/png" if "image/png" in targets else "UTF8_STRING"
    try:
        p = subprocess.run(["xclip", "-selection", "clipboard", "-t", kind, "-o"], env=ENV,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        cur = p.stdout if p.returncode == 0 else b""
    except Exception:
        continue
    if not cur or cur == last:
        continue
    if cur == mine[0]:      # our own echo, once
        mine[0] = None
        last = cur
        continue
    last = cur
    verb = "CLIPIMG " if kind == "image/png" else "CLIP "
    sys.stdout.write(verb + base64.b64encode(cur).decode() + "\n")
    sys.stdout.flush()
