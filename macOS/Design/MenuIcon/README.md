# Menu icon

The approved design uses PingFang SC Medium's 墨 glyph as a transparent cutout in a rounded rectangle. Logical size is 22 × 16 pt, corner radius 4.5 pt, and the centered glyph fits an 11 pt square. `Generate.m` produces 1x/2x PNG previews and a multi-representation TIFF.

Regenerate on macOS with:

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror macOS/Design/MenuIcon/Generate.m -framework AppKit -framework CoreText -o build/generate-menu-icon
build/generate-menu-icon macOS/Design/MenuIcon
cp macOS/Design/MenuIcon/MenuIconTemplate.tiff macOS/Resources/
```

The TIFF is checked in so routine builds do not depend on the installed font version. The `Template` suffix follows AppKit template-image naming. Both normal and alternate input-mode menu entries reference it. Actual input-menu tinting is owned by macOS and requires installed UI acceptance; the design comparison PNG shows simulated appearances only.

`Preview.m` and `preview.png` retain the Regular/Medium/Semibold comparison that led to the Medium choice.
