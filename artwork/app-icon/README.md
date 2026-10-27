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

`Visor.icns` is the compiled macOS icon (the same file actool writes
into the Mac apps beside Assets.car) and `Visor-1024.png` the 1024 × 1024 export (the web app's favicon
and touch icon). Glass translucency is 0.35. `preview.png` matches the PNG.
Regenerate both from `Visor.icon` when the geometry changes.

The repository's icon (.github/icon.png, where Reviews and other tools look
for it) is the same document rendered at 512 points:

    ictool artwork/app-icon/Visor.icon --export-image --output-file .github/icon.png \
        --platform iOS --rendition Default --width 512 --height 512 --scale 1

(`ictool` is in Xcode's Icon Composer.app, Contents/Executables.)
