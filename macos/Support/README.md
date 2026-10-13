# App icon

`AppIcon.icon` is the editable Icon Composer source for **Soft Glow**, the selected
amber glass cursor on a glossy dark tile for BlitzKVM. Its PNG artwork is embedded
in the package, so builds do not depend on the imagegen output directory or a
user's home directory.

Open the package in Icon Composer to edit it. The image layer's additional glass
effects are disabled to preserve the selected artwork; a black base prevents
color leaking through its transparent margins, and Icon Composer supplies the
native mask. The source supports macOS and automatic appearance variants.

Run `make -C macos icon` from the repository root to regenerate the icon using
Xcode's `actool`. No image-generation service or extra dependency is needed.
The app build runs this target automatically before signing.

- `build/icon/Assets.car`: compiled native icon and appearance variants.
- `Support/AppIcon.icns`: generated standalone fallback, with all ten standard
  and Retina representations from 16px through 1024px. Do not edit by hand.
- `build/icon/partial-info.plist`: compiler metadata. Its `CFBundleIconName` and
  `CFBundleIconFile` values match `Info.plist.in`.

The bundle includes both `Assets.car` and `AppIcon.icns` in `Contents/Resources`
and keeps the existing macOS 14.0 deployment target. Only the compiled artifacts
go into the app; the editable source stays in the repository.

Artwork was generated with the built-in imagegen tool on October 11, 2026.
The original generation and selected edit prompts are recorded in
`AppIcon.prompt.txt`. The selected source artwork is retained at its original
1254 × 1254 resolution; Apple's compiler
renders the required output sizes and macOS icon padding.

References: [Apple's Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
and [standard and Retina icon representations](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html).
