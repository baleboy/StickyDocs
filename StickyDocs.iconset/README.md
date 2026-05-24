# StickyDocs.iconset

Generated from `StickyDocs Icon - Paper Stack.html` with current Tweaks.

## Settings used

- **Palette**: Sunlit (warm cream / sage / peach / ivory)
- **Tape**: washi strip at top
- **Handwriting lines**: 3
- **Rotation**: balanced
- **Paper grain**: 0.4
- **Shadow depth**: 0.8

## Contents

Standard macOS `.iconset` — 10 PNGs at the sizes Apple requires:

```
icon_16x16.png         16×16
icon_16x16@2x.png      32×32
icon_32x32.png         32×32
icon_32x32@2x.png      64×64
icon_128x128.png       128×128
icon_128x128@2x.png    256×256
icon_256x256.png       256×256
icon_256x256@2x.png    512×512
icon_512x512.png       512×512
icon_512x512@2x.png    1024×1024
```

Plus `icon_master.svg` — the source SVG at 1024×1024, infinitely scalable.

## Building an `.icns` for your macOS app

On macOS, from the folder that contains this `.iconset`:

```sh
iconutil -c icns StickyDocs.iconset
```

That produces `StickyDocs.icns` — drop it into your Xcode project / `Info.plist`'s `CFBundleIconFile`.

## Regenerating

To re-render with different Tweak settings: open the HTML, adjust Tweaks, then ask me to regenerate the iconset.
