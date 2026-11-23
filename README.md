# PixelFailure

PixelFailure is a macOS image editor built with SwiftUI. It combines seeded generative patterns with a regular layer-based editor, so you can generate something, drop a photo on top, add text and vectors, mask and adjust it, and export the result.

![PixelFailure editor showing a generated flow field artwork](docs/images/pixelfailure-app.png)

## What it does

- **Generators.** Twenty seeded generators: flow fields, waves, rings, phyllotaxis, Truchet tiles, grids, image mosaics, circle packing, contours, stippling, subdivision, space-filling curves, L-systems, differential growth, wave-function tiles and string art, plus GPU noise fields, Voronoi, plasma and reaction–diffusion. Any vector generator can be mirrored, kaleidoscoped, tiled, clipped to a shape or text, or colored from an image. Presets, parameter locks and a Variations grid help explore, and the same settings always give the same output.
- **Layers.** Image, pattern, shape, text, fill, paint, path, adjustment and group layers, with masks, opacity, blend modes and clipping.
- **Color.** sRGB or Display P3 documents at 8 or 16 bits per channel. Embedded profiles are kept on import and written on export.
- **Non-destructive editing.** Transforms and effect stacks don't touch the original pixels. History states can be named, and you can take snapshots.
- **Selections and retouching.** Geometric and freehand selections, magic wand and subject selection, plus feathering, content-aware fill, patch healing and brushes.
- **Vectors and type.** Editable shapes and paths. Text can be styled per range, set inside an area or along a path, and stays vector in SVG exports.
- **Animation.** Keyframe layer properties on a timeline and export the animation.
- **Working with other apps.** Layered PSD import and export, export slices, printing with DPI-aware sizing, and Quick Look thumbnails for project files.
- **Automation.** Batch operations, recordable actions, keyboard shortcuts and AppleScript support.

## Export formats

PNG, JPEG, TIFF, HEIC, WebP, PDF, SVG (including a plotter-ready mode) and layered PSD. Raster formats can embed a color profile. SVG export keeps supported patterns, shapes and outlined text as real vectors instead of rasterizing them.

Projects are saved as `.pixelfailure` document packages that contain everything the project needs.

## Requirements

- macOS 27.0 or later (smart selection uses Vision APIs new in macOS 27)
- Xcode 27 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), if you need to regenerate the Xcode project

## Building

Clone the repo and generate the Xcode project:

```bash
git clone <repository-url>
cd PixelFailure-image-tool
xcodegen generate
```

Then open `PixelFailure.xcodeproj`, pick the **PixelFailure** scheme and run it. To build from the command line instead:

```bash
xcodebuild \
  -project PixelFailure.xcodeproj \
  -scheme PixelFailure \
  -configuration Debug \
  build
```

## Tests

Run them in Xcode with **Product → Test**, or:

```bash
xcodebuild \
  -project PixelFailure.xcodeproj \
  -scheme PixelFailure \
  -destination 'platform=macOS' \
  test
```

## Project layout

```text
PixelFailure/
├── App/          App entry point and automation
├── Core/         Color, parameters, primitives, noise, seeded RNG
├── Document/     Project files, import/export, document operations
├── Effects/      Core Image effects
├── Generators/   Pattern generators
├── Model/        Layers, transforms, effects, palettes, project state
├── Painting/     Brushes and paint sessions
├── Rendering/    Canvas, raster, vector and animation rendering
├── Selection/    Selection tools, rasterization, smart imaging
└── Views/        SwiftUI editor and inspectors
```

The Quick Look extension is in `QuickLookExtension/`. The Xcode project is generated from `project.yml`, so edit that rather than the `.xcodeproj`.

## Status

This is a side project and still early. Expect rough edges.
