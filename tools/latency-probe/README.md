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

   It connects, takes 40 samples about a second apart, prints a JSON report and exits. Its window floats above other
   windows (a covered window presents nothing), and your keyboard and pointer pass it by. Like a self-test, it
   leaves the device library, the Keychain and update checks alone. `--quality auto|minimal|low|balanced|high|maximum`
   sets the stream quality for the run.

The page's mid-gray square is a safety marker: the probe sends a key only while it sees the marker in the video, and
stops as soon as it is gone. So keys never reach another app on the remote when its screen changes.

## Pages

| Page | Use |
|---|---|
| `latency.html` | Black page, the default |
| `latency_busy.html` | The probe over the quality pattern, so keyframes have a desktop's size |
| `latency_motion.html` | The pattern scrolls behind the probe in bursts (`#on=2000&off=4000&speed=1080`: ms, ms, px/s; `#on=0` keeps it still), like scrolling now and then: latency while the stream is busy. It hides the cursor, so it is for keys, not `BLITZKVM_PROBE_POINTER`. `tools/quality-bench/motion_score.py` scores a recording of it at 1:1, full screen |

`keylog_server.py`, run on the remote computer, serves this folder on `127.0.0.1:8777`; open
`http://127.0.0.1:8777/latency_motion.html` there and every key's arrival lands in `keys.log`. Against the report's
`sent_unix`, that splits each sample into the input's delay and the picture's (up to a constant clock offset). Copy
`pattern.png` next to the pages on the remote computer.

## Options (environment)

| Variable | Effect |
|---|---|
| `BLITZKVM_PROBE_POINTER=1` | Moves the pointer between two spots instead of pressing a key; waits for the cursor at the new spot |
| `BLITZKVM_PROBE_WHEEL=1` | A wheel step instead of a key (the page flips its square on wheel events too) |
| `BLITZKVM_PROBE_KEYFRAME_LEAD=S` | Asks for a keyframe S seconds before each key: the cost of a large frame in flight (a still refresh, a repair). Use `latency_busy.html` (the probe page over the quality pattern), so keyframes have a desktop's size |
| `BLITZKVM_PROBE_FULLSCREEN=1` | Measures with the window in full screen |
| `BLITZKVM_PROBE_PAIR_GAP=S` | Presses an unmeasured key first, then the measured one S seconds later (to hit the still refresh) |
| `BLITZKVM_DISPLAY_SYNC=1` | A/B: the old presentation (display sync on) |

## Report

- `decoded_ms`: input → decoded frame that shows the change.
- `presented_ms`: input → that frame on screen.
- `decode_to_present_ms` and `stages_after_decode_ms`: render start, drawable, commit, GPU done, on screen.
- `engine_to_decoded_ms`: engine receive → decoded in the app (IPC + decode), every frame.
- `raw`: each sample's decoded and presented times; `sent_unix`: when each sample's input was sent (Unix seconds),
  to line samples up with other logs.

Each has median, p10, p90, min, max and mean in ms.
