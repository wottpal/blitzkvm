# Latency probe

Measures input-to-photon latency through the whole app: a key press (or a pointer move) is sent to the remote, and the
app records when the decoded picture shows the change and when that frame reached the local screen
(`MTLDrawable.presentedTime`). The remote computer's own input-to-display time is part of every sample, as it is for
the user.

## Run

1. On the remote computer, open `latency.html` from this folder in a browser, full screen (serve it from any machine
   on the LAN, for example `python3 -m http.server 8765` here). Every key press flips a large square between black and
   white.
2. Run the app with the probe, against a device whose target is **not** the Mac you run it on:

   ```sh
   "macos/build/BlitzKVM.app/Contents/MacOS/BlitzKVM" --device <address> --latency-probe 40
   ```

   It connects, takes 40 samples about a second apart, prints a JSON report and exits.

The page's mid-gray square is a safety marker: the probe sends a key only while it sees the marker in the video, and
stops as soon as it is gone. So keys never reach another app on the remote when its screen changes.

## Options (environment)

| Variable | Effect |
|---|---|
| `BLITZKVM_PROBE_POINTER=1` | Moves the pointer between two spots instead of pressing a key; waits for the cursor at the new spot |
| `BLITZKVM_PROBE_FULLSCREEN=1` | Measures with the window in full screen |
| `BLITZKVM_PROBE_PAIR_GAP=S` | Presses an unmeasured key first, then the measured one S seconds later (to hit the still refresh) |
| `BLITZKVM_DISPLAY_SYNC=1` | A/B: the old presentation (display sync on) |

## Report

- `decoded_ms`: input → decoded frame that shows the change.
- `presented_ms`: input → that frame on screen.
- `decode_to_present_ms` and `stages_after_decode_ms`: render start, drawable, commit, GPU done, on screen.
- `engine_to_decoded_ms`: engine receive → decoded in the app (IPC + decode), every frame.

Each has median, p10, p90, min, max and mean in ms.
