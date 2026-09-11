# MOIST brand — where these came from

**The master is `~/Desktop/moist.psd` (6300 × 2700). Bryan made it. Do not redraw it.**

Everything in this folder was mechanically separated out of that PSD's flattened composite — no
letterform, curve, or spacing was ever recreated. If a variant is needed that cannot be cut out of the
composite, **ask Bryan to export it from the PSD**; do not approximate it.

## How the separation was done

Pillow reports 23 layers in the PSD but hands back the same flattened composite for every one of them, so
per-layer export was not usable. The artwork is exactly two colours, which makes colour separation exact:

1. `sips -s format png moist.psd` → clean 6300×2700 RGB composite.
2. Per pixel, `t = dist_to_green / (dist_to_gold + dist_to_green)`; alpha is `t` ramped from 0.30→0.70.
   Pure green becomes fully transparent, pure gold fully opaque, and antialiased edges stay smooth.
3. Row/column profiling found the bands and letters: wordmark `y 921–1900`, tagline `y 2032–2173`,
   letters `M 1212–2126 · O 2248–3166 · I 3257–3448 · S 3530–4299 · T 4340–5092`.
4. The drop was isolated by flood-filling the O's ring inward from its bounding-box edges; the gold that
   the fill never reaches is the drop.

## Files

| File | What it is |
|---|---|
| `moist-lockup.png` | wordmark + tagline, gold on transparent |
| `moist-wordmark.png` | MOIST only |
| `moist-tagline.png` | `mini.open.interface.system.tools` only |
| `moist-mark.png` | the O with the drop — the standalone mark |
| `moist-drop.png` | the drop alone |
| `*-mask.png` | same shapes in **white** on transparent |
| `moist-icon-1024.png` | app icon source — mark on brand green |
| `AppIcon.icns` | built from the above with `iconutil` |
| `palette.json` | the four colourways + type stack |

## Recolouring

Use the `-mask.png` files with CSS `mask-image` and a `background-color` of the theme's accent. That is how
one asset serves all four colourways — proof sheet at `../docs/colorways.png`. Never ship a
per-theme recoloured copy; there is one shape, tinted at render time.

## Type

**Futura** for headings and the wordmark, **Arial** for body — both taken from the artwork.
`renderer/index.html` already leads `--heading-font` with Futura, so headings need no change.

---

## 2026-09-11 — Sav's mascot and colourways

The mermaid and the moon are hers. Two photos of her skateboard (a black-outline mermaid on a
holographic scale sticker; a blue halftone moon, eye and stars on white paint) were traced
mechanically — nothing redrawn:

1. Upscaled 4× (mermaid) / 3× (moon) with Lanczos.
2. Mermaid: every pixel darker than lum 85 is ink. Moon: red channel < 150 AND blue − red > 30
   (the paint photographs blue-white, so "blue" alone selected the whole board), blurred 6px to
   fuse the halftone dots, thresholded.
3. Board edges and two dust specks masked off by rectangle; `potrace -a 1 -O 0.2`, turdsize
   1500 / 400.
4. `fill="currentColor"` so CSS tints the one file per colourway, like the `-mask.png` files.

| File | What it is |
|---|---|
| `moist-mermaid.svg` | the mascot — top of the sidebar, and the app icon |
| `moist-moon.svg` | moon, winking eye, tear and five stars — beside the wordmark, and the first-run mark |
| `moist-icon-1024.png` / `AppIcon.icns` | white mermaid on brand blue, same chamfer as before |
| `fonts/` | Orbitron 400/500/700 and Silkscreen 400, both SIL OFL |

`palette.json` now carries the four blue colourways; the old green/gold values are gone from the app.
The PSD wordmark and tagline masks are untouched and still tint through the accent.
