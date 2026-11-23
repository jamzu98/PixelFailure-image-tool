# PixelFailure roadmap (v3)

v3 aims to make PixelFailure hold up as a professional editor, while keeping what sets it apart: seeded, deterministic generative art. The direction, set in November 2026:

- **Generation stays procedural.** No AI image generation.
- **Core ML is allowed for retouching.** Bundled models may power real inpainting and super-resolution.
- **Native Apple frameworks come first** wherever they win on performance: Metal, Core Image, Accelerate/vImage, Vision and Core ML.

The rules carried over from v1 and v2 still hold:

- The image store is append-only in memory.
- Model changes must decode old documents (Codable back-compat).
- Every destructive bake calls `recordSourceIfNeeded()`.
- Every `CGContext` comes from `ColorSettings`.
- The same seed gives the same art.

## Phase 1: Foundation ✅ (Nov 2026)

- **Clipping masks:**
  - The clipped layer keeps its own opacity and blend mode.
  - Every layer in a clipped run clips to the base layer, not to the clipped layer below it.
- **PSD export:**
  - Layer opacity is no longer applied twice.
  - Adjustment layers export as pixel layers instead of being dropped.
  - Layer names are written in Unicode.
- **Saving:**
  - A save writes only the images that the current state and named snapshots still use.
  - Images that haven't changed reuse their existing file wrappers.
- **Crash recovery:** autosaves are written to a `.recovery` folder in the background, adding only new images each time. Archives in the old single-file format still open.
- **Core Image:** one shared Metal-backed `CIContext` works in half-float linear space. Super Resolution keeps the layer's gamut and bit depth.
- **Viewport:** full-quality effect stacks and pattern regeneration render in the background behind the closest cached content. Exporters still render exactly.
- **Long operations:**
  - Content-Aware Fill and Super Resolution run in the background and show a status-bar indicator.
  - Super Resolution is capped at 16384 px.
  - Raster and PDF export run in the background.
  - Delete and Fill now encode their PNG in the background.
- **Brushes:**
  - The buffer is snapshotted only when the viewport or the commit needs it.
  - Smudge copies only the area of each dab.

## Phase 2: Engine (Metal)

- **Metal compositor:**
  - Replace the CoreGraphics tile rasterizer with `CAMetalLayer` tiles and blend modes written as fragment shaders.
  - The shaders also bring Linear/Vivid/Pin Light, Hard Mix, Subtract, Divide, Darker/Lighter Color and Pass Through.
  - Work in a half-float linear space, with EDR output.
- **One renderer:** remove the SwiftUI `CanvasRenderer`, so the canvas uses only one renderer.
- **Caching:**
  - Cache adjustment and clipping rasters per layer, instead of re-rendering the whole canvas.
  - Replace the whole-model `hashValue` scene key with a document revision counter.
- **vImage:** use it for CPU resampling, histograms and morphology.

## Phase 3: Pro editing parity

### Tools

- On-canvas Text, Shape, Gradient (with stop handles) and Paint Bucket tools.
- Spot Heal, and Patch, which hooks up the existing `patchSelection`.
- Real healing that matches texture, replacing clone at 45%.
- Crop with aspect-ratio presets, straighten and overlays.
- On-canvas distort, perspective and warp handles.
- Non-uniform layer scale.
- Liquify (a Metal mesh).

### Selections

- Quick-select brush.
- Select & Mask: refine the Vision matte, smooth, shift edge, decontaminate colors.
- Color Range, Quick Mask and alpha channels.
- Undoable selections, and ⌘-click a layer thumbnail to select its pixels.
- Magic wand and eyedropper sampling at full resolution.

### Adjustments

- Curves and Levels per channel, with a live histogram.
- Hue/Saturation with colorize, Color Balance, Channel Mixer, Black & White and Selective Color.
- Gradient Map with editable stops.
- `.cube` LUTs.
- Real RAW processing through `CIRAWFilter`.
- A mask on each effect.

### Layers

- Fill opacity and blend-if.
- The full set of layer styles, including a true stroke.
- Vector masks.
- Embedded smart objects.

### Import and export

- EXIF, IPTC, XMP and DPI metadata.
- Open PNG, JPEG and HEIC directly as documents.
- PSD groups, masks, 16-bit and RLE.
- A fit/fill option on export, and AVIF.

## Phase 4: Deeper procedural generation ✅ (Nov 2026)

- **Noise core:** deterministic Simplex, Worley, ridged and billow noise, plus domain warp and curl (`Core/NoiseField.swift`). Flow Field and Waves expose them; GameplayKit's `GKNoise` was avoided so output can't drift between OS versions.
- **Shared stages for every vector generator** (`Generators/GeneratorPipeline.swift`): symmetry (mirror, radial, kaleidoscope), repeat tiling with brick offset, clipping inside or outside a shape, text or path layer, and colors sampled from an image. Settings live in `params` under `stage.` keys. Clipping uses our own polyline clipper, because `CGPath.lineIntersection` emits stray segments.
- **New vector generators:** Circle Packing, Contours, Stipple, Subdivision, Space-Filling Curve, L-System, Differential Growth, Wave Tiles, String Art.
- **GPU raster generators:** Noise Field, Voronoi, Plasma, Reaction–Diffusion, rendered per viewport tier through the progressive path and usable as pattern masks. Kernels compile at runtime from `MetalShaderSource`, so building needs no Metal Toolchain download.
- **Glitch effects:** Pixel Sort, Datamosh, Noise RGB Shift, Dither (Bayer, blue noise, Floyd–Steinberg). The GPU ones run as a tile-aware `CIImageProcessorKernel`.
- **Workflow:** built-in and user presets, parameter locks, Variations with Mutate/Wild modes rendered off the main thread, session seed history, and plotter-ready SVG export.
- **Guard:** golden digests of the original seven generators prove old documents render unchanged.

Still open for a later pass: image-luminance and noise modulation of individual sliders, variable-width strokes and hatching, and chaining one generator's points into another.

## Phase 5: Core ML retouching

- **Content-Aware Fill and Remove** use a LaMa-class inpainting model:
  - Run on a context crop around the selection at 512 px.
  - Respect the soft matte, and feather the seam.
  - Keep the current algorithm as the fallback.
- **Super Resolution 2× and 4×** use a Real-ESRGAN-class model, tiled with overlap, with `computeUnits = .all`.
