# Text upscaler

The app enlarges the remote picture exactly 2× (Actual Size on a Retina screen) with a small convolutional network instead of FSR: `macos/Sources/JetKVMDesktop/TextUpscaler.swift`, weights in `TextUpscalerWeights.swift`. These two scripts make the weights.

| File | Purpose |
|---|---|
| `gen.swift` | Random desktop-like scenes (fonts, sizes 9–28 px, light, dark and colored backgrounds, buttons, lines, gradients), drawn by CoreText at 1× and natively at 2× with the same layout |
| `train.py` | Trains the network on those pairs (luma only; L1 loss on 64×64 crops), scores it against the native 2× test pattern, and writes the weights as Swift |

```bash
cd tools/text-upscaler
swiftc -O gen.swift -o /tmp/gen && /tmp/gen /tmp/pairs 3000 11     # 3000 pairs, seed 11
(cd ../quality-bench && swift make_pattern.swift pattern.png && swift make_pattern.swift pattern2x.png 2)
uv venv -q venv && uv pip install -q --python venv/bin/python torch numpy pillow scikit-image
venv/bin/python train.py /tmp/pairs --channels 8 --steps 30000 \
  --swift ../../macos/Sources/JetKVMDesktop/TextUpscalerWeights.swift   # ~2.5 min on Apple silicon (MPS)
```

## Results

Measured against the test pattern drawn natively at 2×, on the decoded stream of a still screen and through the app's own renderer (luma PSNR in dB / SSIM):

| Region | Nearest | Catmull-Rom | FSR 1 | This network (8 channels) |
|---|---|---|---|---|
| Light text | 21.2 / 0.944 | 22.8 / 0.951 | 23.0 / 0.955 | 23.9 / 0.972 |
| Dark text | 21.8 / 0.925 | 23.2 / 0.928 | 23.5 / 0.941 | 24.8 / 0.965 |
| Colored text | 24.6 / 0.941 | 25.9 / 0.950 | 26.3 / 0.957 | 28.5 / 0.978 |
| Code | 20.8 / 0.944 | 22.3 / 0.948 | 22.5 / 0.952 | 23.9 / 0.972 |
| 9–12 px text | 19.4 / 0.927 | 20.5 / 0.931 | 20.5 / 0.934 | 20.0 / 0.940 |

FSR's sharpening strength changes none of these by more than 0.1 dB. 16 channels add 0.1–0.8 dB at 3.4× the work; 8 channels cost 1,640 multiply-adds per source pixel.

**Cost:** a 3000×2000-pixel view on an M4 Max takes about 2 ms of extra GPU time per changed frame. A compare pass skips the network when the picture is unchanged. A GPU that needs more than 8 ms per frame falls back to FSR for the session.
