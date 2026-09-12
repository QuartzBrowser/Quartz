# Quartz app icon

`AppIcon.png` is the 1024 × 1024 master artwork with a transparent margin around
the rounded porcelain tile. The faceted crystal Q uses the blue and teal colors
from Quartz's native start page, with restrained amber and rose reflections.

Regenerate the macOS icon with the built-in macOS image tools:

```sh
Scripts/generate-app-icon.sh
```

This exports the standard 16, 32, 128, 256, and 512 point representations at 1×
and 2× into `Sources/Quartz/Resources/AppIcon.icns`. SwiftPM includes the icon
for `swift run Quartz`, and the packaging script includes it in the macOS app's
Resources directory and declares it in Info.plist.

The master uses the sRGB color space. Preserve its transparent margin when
exporting additional sizes so the rounded tile displays cleanly against light
and dark backgrounds.
