# PixelFailure Roadmap

The path from generative-art sandbox to a respectable alternative to
Photoshop / Affinity Photo / Pixelmator Pro — while keeping the things none of
them have: seeded generators, palettes as first-class citizens, and true-vector
SVG export.

Each stage ships on its own: builds green, tests extended, live smoke test,
committed, installed. One stage per working session is the intended pace.
Order matters — early stages are foundations the later ones build on.

---

## Stage 1 — Interop quick wins ✅

Small, zero architectural risk, immediate credibility.

- Paste images from the system clipboard as layers (screenshots, browser copies)
- Copy layers **out** as PNG for other apps
- JPEG / TIFF / HEIC export with a quality slider (WebP waits for Stage 9)
- Layer thumbnails in the sidebar
- Flip horizontal / vertical
- Lock layers (immune to move/scale/rotate/paint, still selectable in sidebar)
- Trackpad scroll pans the canvas; ⌥/⌘-scroll zooms anchored at the pointer

## Stage 2 — Selections engine

The foundation half of everything later depends on. Three shippable sub-phases:

- **2a Core**: selection model (vector path + rasterized grayscale mask, session
  state), rectangular/elliptical marquee, freehand + polygonal lasso,
  marching-ants overlay, ⌘A / invert / deselect, ⇧-add / ⌥-subtract
- **2b Integration**: painting clipped to the selection, delete/fill within
  selection, copy/paste selection as a new layer, selection → layer mask
- **2c Smart**: magic wand (tolerance flood fill over the composite),
  feather / expand / contract via Core Image morphology

## Stage 3 — Layer system depth

The model refactor; do it before more features pile onto the flat layer list.

- Groups as nested layers (group opacity/blend/mask via transparency groups)
- Multi-select: move/transform/delete several layers at once
- Align & distribute commands
- Numeric X/Y/W/H fields in the inspector
- Drag layers into/out of groups in the sidebar

## Stage 4 — Core adjustments

The bread-and-butter correction set, on the existing effect-stack architecture.

- Curves (interactive curve editor) and Levels (with histogram)
- Targeted HSL, white balance, vibrance, shadows/highlights
- ParamValues grows array storage (backward compatible) for curve points

## Stage 5 — Workspace

- Rulers + draggable guides (persisted per document)
- Smart guides: live edge/center alignment vs. other layers while dragging
- Grid overlay, navigator minimap

## Stage 6 — Compositing depth

- Adjustment layers (effect stack applied to everything below, maskable)
- Clipping masks (layer clipped by the alpha of the layer below)
- Layer styles: drop shadow, stroke, outer glow

## Stage 7 — Retouch + brush engine v2

Includes migrating viewport input to an NSView event layer (tablet pressure,
precise scroll — things SwiftUI gestures can't deliver).

- Pressure-driven size/opacity, stroke smoothing, spacing/scatter/jitter
- Brush presets
- Clone stamp, healing brush, smudge, dodge/burn

## Stage 8 — Typography & vector

- Paragraph text boxes with wrapping; text on a path; per-range styling
- Pen tool with a bezier path layer kind + node editing overlay
- Boolean path ops (union/subtract/intersect via CGPath)

## Stage 9 — Pro interop & platform

- PSD import (layers, names, opacity, blend modes)
- PDF export/import, RAW import, WebP
- Quick Look thumbnails for `.pixelfailure`, Share menu, print
- Real app icon, onboarding pass

## Stage 10 — ML & performance

- Select Subject / remove background (Vision) → selection or mask
- Content-aware fill via bundled inpainting model; optional super-resolution
- Tiled/Metal viewport once large documents outgrow SwiftUI Canvas

## Stage 11 — Generative signature features

The moat — things Photoshop/Affinity/Pixelmator can't do:

- Variations grid: render N seed variants of the composition, click to keep one
- Mask-from-pattern: any generator as a layer mask
- Palette harmonies generator; per-layer seed history scrubbing
- Animation export: interpolate seeds/params over time → looping MP4/GIF
  (album visualizers)
