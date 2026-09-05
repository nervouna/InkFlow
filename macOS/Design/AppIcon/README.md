# App icon sources

- `app-icon-input-1024.png`: approved opaque, unmasked 1024-square artwork.
- `InkFlow.icon`: editable Icon Composer document with the same embedded artwork. Layer glass, group specular, translucency, and shadow effects are disabled.
- `app-icon-rendered-1024.png`: Icon Composer Default appearance export, including the system icon shape. This is a final static render, not a source for another masking pipeline.

After editing the document in Icon Composer, export its iOS/macOS Default appearance at 1024pt, 1x to `app-icon-rendered-1024.png`. Run `bash macOS/scripts/build-icon.sh` to package all ICNS resolutions. The normal app build runs this automatically; the custom bundle consumes `AppIcon.icns` without applying a second mask. Input-source/menu icons are separate.
