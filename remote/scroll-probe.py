#!/usr/bin/env python3
"""Log wheel events arriving in the X session. Observes only, changes nothing.

Passive-grabs buttons 4-7 in SYNC mode and immediately replays every one of
them, so scrolling behaves exactly as it normally would while this runs.
"""
import sys, time
from Xlib import X, display

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
AXIS = {4: "up", 5: "down", 6: "left", 7: "right"}

d = display.Display()
root = d.screen().root
for b in AXIS:
    root.grab_button(b, X.AnyModifier, True, X.ButtonPressMask,
                     X.GrabModeSync, X.GrabModeAsync, X.NONE, X.NONE)

print("recording %.0fs - scroll now" % DURATION, flush=True)
events = []
end = time.monotonic() + DURATION
while time.monotonic() < end:
    if d.pending_events() == 0:
        time.sleep(0.002)
        continue
    e = d.next_event()
    if e.type == X.ButtonPress and e.detail in AXIS:
        events.append((time.monotonic(), AXIS[e.detail]))
    d.allow_events(X.ReplayPointer, X.CurrentTime)
    d.flush()

for b in AXIS:
    root.ungrab_button(b, X.AnyModifier)
d.flush()

if not events:
    print("NO wheel events seen")
    raise SystemExit(0)

t0 = events[0][0]
gaps = [events[i][0] - events[i-1][0] for i in range(1, len(events))]
# A gap over 250 ms means a new gesture.
gestures, cur = [], 1
for g in gaps:
    if g > 0.25:
        gestures.append(cur); cur = 1
    else:
        cur += 1
gestures.append(cur)

print("total wheel events: %d over %.1fs" % (len(events), events[-1][0] - t0))
print("gestures detected:  %d" % len(gestures))
print("events per gesture: %s" % gestures)
print("median per gesture: %d" % sorted(gestures)[len(gestures)//2])
if gaps:
    inner = sorted(g for g in gaps if g <= 0.25)
    if inner:
        print("gap between events within a gesture: median %.1f ms, min %.1f ms"
              % (inner[len(inner)//2] * 1000, inner[0] * 1000))
        print("=> event rate inside a gesture: %.0f per second" % (1.0 / inner[len(inner)//2]))
