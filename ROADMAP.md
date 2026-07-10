# PixelFailure Roadmap — v2: the professional gap

Roadmap v1 (generative-art sandbox → real image editor) has shipped: layer
system with groups, selections engine, adjustments, compositing depth, retouch
tools, pen/node vectors, PSD import, ML selection & fill, and the animation
timeline. This file is v2: the stages that separate a *capable* editor from a
*professional* one — comparable to Photoshop, Affinity Photo, and Pixelmator
Pro — while keeping the things none of them have: seeded generators, palettes
as first-class citizens, true-vector SVG export, and the animation timeline.

Each stage ships on its own: builds green, tests extended, live smoke test,
committed, installed. One stage per working session is the intended pace.
Order matters — the early stages change the pixel format and the model, and
every later stage builds on them. Retrofitting bit depth or non-destructive
transforms after more features pile on only gets more expensive.

Standing invariants every stage must preserve:

- **RenderItem parity** — viewport (`GraphicsContext`), PNG export
  (`CGContext`), and the SVG writer render identically.
- **Append-only image store** — never mutate stored pixels; commit by writing
  a new key and swapping the reference (one undo step for free).
- **Codable back-compat** — old `.pixelfailure` documents keep opening;
  new model fields decode as optional (fixture test guards this).
- **Determinism** — same seed, same art.

---

## Stage 1 — Color management & 16-bit ✅

The foundation. Everything downstream (brushes, effects, RAW) builds on the
buffer format; doing this first invalidates the least existing work and the
most future work. 8-bit sRGB banding on a smooth gradient is where
professionals walk away.

- Honor embedded ICC profiles on import: convert incoming images into the
  working space instead of assuming sRGB
- Working-space setting per document: sRGB or Display P3; wide-gamut color
  picker
- Embed the working-space profile in every raster export
- 16-bit-per-channel option for the image store and paint buffers; float
  compositing so curves/levels edits stop banding
- Back-compat: per-image bit-depth tag in the store; existing 8-bit documents
  open unchanged and stay 8-bit until converted

Touchpoints: `Core/RGBAColor.swift`, `Painting/PaintSession.swift`,
`Rendering/ImageEncoder.swift`, `Rendering/PNGExporter.swift`, and the
Core Image working space in `Effects/CoreImagePipeline.swift`. SVG export
stays 8-bit hex — it's vector. CMYK and soft proofing are explicitly deferred
(see the end of this file).

## Stage 2 — Smart objects: non-destructive raster transforms ✅

Shipped as `Layer.source: LayerSource?` — a snapshot of the layer's full
pre-bake kind and scale, recorded the first time any destructive operation
bakes pixels (rasterize, super-resolution, fill/delete selection,
content-aware fill, painting). "Revert to Original" in the image inspector
restores it across save/reopen; the append-only store keeps the bytes.
Rasterize also stopped baking below native resolution, so a scaled-down
layer keeps its full pixel fidelity. Transforms themselves were already
live (never baked), so nothing re-samples from a bake.

## Stage 3 — Tiled/Metal viewport & proxy rendering ✅

Shipped as a display-linked retained `CALayer` tile grid that consumes
immutable `RenderItem` snapshots and draws every tile through the same Core
Graphics ground truth as PNG export. Complete replacement batches are swapped
atomically, so the prior pixels stay visible while updated tiles render in the
background. Model diffs now produce canvas-space dirty
rectangles for isolated layer edits and conservatively invalidate the full
canvas for structural, palette, color-space, background, adjustment, and
canvas-effect changes. The navigator follows render revisions instead of a
whole-model hash. Continuous parameter edits, animation scrubbing, and
playback use a 512-pixel proxy mip, upgrade immediately to the normal preview,
then restore native-resolution raster/effect rendering after a short idle.
Pan and zoom update the retained grid transform immediately; zoom replaces the
old LOD only after the next visible grid is complete. Exports remain unchanged
and always request full quality.

## Stage 4 — Transform suite ✅

What compositing work reaches for constantly: fitting artwork onto a surface,
correcting a photographed cover, distorting type.

- Skew and free distort (corner-pin homography)
- Perspective transform and perspective crop
- Warp mesh
- Canvas rotation for drawing (view-only, non-destructive)

Builds on Stage 2 (transforms stay non-destructive) and Stage 3 (live
preview). Touchpoints: `Model/LayerTransform.swift` grows beyond affine —
SVG/PNG/viewport parity must hold for every new transform kind.

Shipped as optional normalized deformation geometry on `LayerTransform`:
editable skew, corner-pin and regular warp meshes share triangle maps across
the viewport, CGContext exporter, and true-vector SVG writer. Perspective crop
uses the distorted bounds without baking pixels. Canvas rotation lives only in
`EditorState`, so drawing can rotate freely without changing the document.

## Stage 5 — Text engine v2 ✅

Text layers are currently single-run point text. Pro-grade typography means:

- Paragraph/area text boxes with wrapping and vertical alignment
- Per-range styling: mixed fonts, sizes, weights, and colors in one layer
- Text on a path
- OpenType features (ligatures, alternates, small caps) and kerning controls

Keep outlining through `Rendering/TextOutliner.swift` so SVG export stays
true-vector — that's a differentiator, not a limitation.

Shipped with wrapping area boxes, vertical and horizontal alignment,
per-range font/weight/size/color runs, editable path layers as baselines,
ligature/small-cap/stylistic-alternate controls, and explicit tracking.
CoreText output is still converted to paths before reaching any renderer.

## Stage 6 — Brush engine v2 ✅

The NSEvent input layer with tablet pressure already exists
(`Views/CanvasViewport.swift`); this stage is about the mark itself.

- Custom brush tips and grain/texture
- Spacing, scatter, angle and size jitter
- Stroke stabilization / smoothing amount
- Preset browser with import/export; ABR import

Shipped with deterministic spacing/scatter/size/opacity/angle dynamics,
elliptical custom tips, procedural grain, smoothing and tablet pressure. The
preset browser reads/writes `.pfbrush`; ABR names and dynamics import with a
documented textured-tip fallback for unsupported proprietary sampled pixels.

## Stage 7 — History & recovery ✅

Single linear undo isn't enough for long sessions.

- History panel with named states; click to jump
- Document snapshots
- Autosave and crash recovery of unsaved documents

The append-only image store already gives one-undo-per-stroke; the history
panel hangs off the same mechanism rather than a new one.

Shipped with a 200-state named session history, clickable inspector history,
persistent named document snapshots, and delayed atomic recovery archives for
unsaved documents. History and snapshots swap models only; stored images remain
append-only and referenced keys stay recoverable.

## Stage 8 — Photo & retouch completeness ✅

Design-first ordering pushed this behind text and brushes, but a professional
tool can't lack a sharpen filter.

- Sharpen (unsharp mask) and noise reduction as first-class stack effects —
  promote the `CISharpenLuminance` buried in `Selection/SmartImaging.swift`
- Patch tool (selection-based heal)
- Lens and chromatic-aberration correction
- RAW develop module: linear-light exposure/highlights/white-balance pipeline
  (depends on Stage 1's 16-bit buffers)

Shipped with non-destructive unsharp mask, noise reduction, lens distortion /
vignette and chromatic-aberration effects; selection-based patch healing; and
a linear-light RAW develop stack that preserves the document's 16-bit output.

## Stage 9 — Interop round-trip & print model ✅

PSD import exists; collaboration is still one-way, and the canvas is pure
pixels.

- PSD **export** (layers, names, opacity, blend modes)
- PSD import fidelity pass (groups, masks, text where feasible)
- DPI / print-size model: documents know their physical size; print dialog
  and exports honor it
- Export slices and @1x/@2x/@3x asset export
- Artboards (stretch goal)

Shipped with layered 8-bit RGB PSD export (names, pixels, visibility, opacity,
clipping and supported blend modes), the existing layered importer fidelity
path, persisted DPI/physical-size metadata, DPI-aware PDF pages, named export
slices, and @1x/@2x/@3x asset output. Artboards remain the stated stretch goal.

## Stage 10 — Automation & ecosystem ✅

Late-stage, but a big part of why studios can't leave Photoshop.

- Batch export / batch apply
- Recordable actions (macro record & replay)
- Shortcuts and AppleScript support
- Plugin API — aspirational; scope only after the above ship

Shipped with multi-file batch application, Codable macro actions with in-app
record/replay, a shared front-document automation bridge for Shortcuts and
AppleScript, and a versioned plugin manifest/action contract. Dynamic plugin
loading and a marketplace remain deferred with the marketplace non-goal below.

---

## Deferred / non-goals (for now)

- CMYK editing and soft proofing — revisit only if print-shop delivery
  becomes a real need; P3 PDFs cover most modern print workflows
- HDR editing and display
- Plugin marketplace

## Protect the moat

Whatever ships, don't regress the things the big three can't do: seeded
deterministic generators, first-class palettes, true-vector SVG export, the
variations grid, and the generator animation timeline.
