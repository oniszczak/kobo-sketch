# Colour Sketch

A finger-drawing pad for the Kobo Clara Colour, written as a KOReader plugin
in Lua and launched from NickelMenu.

While your finger is down, the line is drawn in black using the panel's
fastest refresh mode (A2). When you lift your finger, the line is repainted in
its real colour using the Kaleido colour waveform, with hardware dithering
turned off.

## Install

With the Kobo mounted:

```sh
./tools/fetch-koreader-src.sh   # once: copies KOReader's sources for the tests
./tools/install.sh
```

This copies `coloursketch.koplugin` into `.adds/koreader/plugins/` and
`nickelmenu/coloursketch` into `.adds/nm/`, then runs `dot_clean`.

## Use

* **NickelMenu → Colour Sketch** starts KOReader straight into the pad.
  **Menu → Exit to Kobo** returns to Nickel.
* Inside KOReader it's under **Tools → Colour sketch**.
* Toolbar: the top row is 10 colours. The bottom row has **Size** (cycles
  4/8/16/32 px), **Eraser**, **Fill** (toggles flood-fill: tap an enclosed
  area), **Undo**, **Redo**, and **Menu** (New, Open, Save, Save as new,
  Clear, Refresh screen, Colour test).
* Drawings are saved as PNGs in `Drawings/` on the Kobo's USB drive.

## Tuning the colours

The colours and brush sizes live in `coloursketch/palette.lua`. **Menu →
Colour test** shows each palette colour and some alternates as a block and at
every brush size, so you can compare them on the screen.

## Known trade-offs

* While you draw, A2 also hits nearby coloured pixels inside the same
  refresh rectangle, so they can briefly show as black or white. They're
  restored when you lift your finger.
* Colour shows at 150 ppi (the panel is 300 ppi in black and white), so the
  4 px brush looks faint in colour.
* The plugin assumes an RGBA framebuffer. The Clara Colour has one; some
  other colour Kobos run BGR and would show red and blue swapped.

## Tests

```sh
luajit tools/test_canvas.lua   # brush geometry, flood fill, undo/redo
luajit tools/test_pad.lua      # touch flow, refresh modes, toolbar
luajit tools/test_plugin.lua   # NickelMenu launch, exit, files
```

These run against KOReader's real `Blitbuffer`, taken from the device by
`fetch-koreader-src.sh`. The UI modules are stubbed.

## Licence

Copyright (C) 2026 oniszczak. Licensed under the GNU Affero General Public
License v3.0, the same licence as KOReader. See [LICENSE](LICENSE).
