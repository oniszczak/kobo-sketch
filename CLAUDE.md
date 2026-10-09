# Working notes

KOReader plugin (`coloursketch.koplugin/`) plus a NickelMenu entry
(`nickelmenu/coloursketch`). See README.md for what it does.

## Before installing, always

```sh
./tools/fetch-koreader-src.sh   # after any KOReader update on the device
luajit tools/test_canvas.lua && luajit tools/test_pad.lua && luajit tools/test_plugin.lua
```

`tools/install.sh` runs the tests too.

## Never guess a KOReader API

Read it in `.koreader-src/` (copied from the device, so it's the exact
version that runs there). The colour/refresh behaviour is in
`ffi/framebuffer_mxcfb.lua` (`mxc_update`, `refresh_kobo_mtk`). Touch input
is in `frontend/device/input.lua` (`handleTouchEvSnow`; the Clara Colour uses
the snow protocol, so a lift arrives as `id == -1` from `BTN_TOUCH:0`).

## Design decisions to preserve

- **Colour without dithering.** KOReader only uses the Kaleido waveforms
  (GLRC16/GCC16) when a refresh carries the dither hint, and on MTK that hint
  also turns on HW dithering. While the pad is open it overrides
  `Device:canHWDither()` to false and forces `Screen.hw_dithering` on. It must
  restore both in `onCloseWidget`.
- **Raw touches, not gestures.** The pad wraps
  `gesture_detector.feedEvent`. A contact belongs to the pad only if it
  *started* while the pad was topmost, and the pad's contacts are never passed
  to the gesture detector. Otherwise the lift that opens a dialog (Menu) also
  becomes a tap, delivered to that dialog, which closes it at once. Other
  contacts are passed through untouched.
- **The preview and the final stroke share one geometry** (`Canvas.capsule`).
  That's how the colour refresh on lift covers every pixel the A2 preview
  touched.
- The canvas is RGB32. The brush is not antialiased, so flood fill can use
  exact colour matching.

## Device

Clara Colour: KOReader v2026.03, firmware 4.46. The framebuffer is
1072x1448 at 32bpp, RGBA (not BGR). After copying, run `dot_clean -m`.
