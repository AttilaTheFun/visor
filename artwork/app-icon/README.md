# Visor app icon

`Visor.icon` is the editable Apple Icon Composer document shared by the iOS,
macOS, and menu bar app targets. Open it in Icon Composer to adjust materials
and appearance variants. Bazel compiles it through the app_icons attribute.

The frontal geometric mask uses an ivory forehead, paired ivory jaw facets,
and a red visor on a charcoal background. The source SVG layers in `layers/`
use a shared 1024 × 1024 canvas; their imported copies live in
`Visor.icon/Assets/`. Keep both copies in sync when changing geometry.

The icon intentionally contains no text, facial features, or baked-in corner
mask. Icon Composer supplies the platform shape and material treatment.

## Exports

`Visor.icns` is the compiled macOS icon (bundled as a resource in the Mac
apps) and `Visor-1024.png` the 1024 × 1024 export (the web app's favicon
and touch icon). Glass translucency is 0.35. `preview.png` matches the PNG.
Regenerate both from `Visor.icon` when the geometry changes.
