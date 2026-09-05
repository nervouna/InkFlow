# Runtime dependencies

`macOS/scripts/dependencies.sh` pins source URLs and SHA-256 digests. Archives live only in ignored `build/deps`. No dependency manager or network connection is used by the installed app.

- librime 1.17.0, upstream revision `33e78140250125871856cdc5b42ddc6a5fcd3cd4`: official universal macOS binary. BSD license in `Licenses/librime.txt`. The release dylib links only macOS system libraries and carries its own transitive engine dependencies.
- rime-pinyin-simp revision `0c6861ef7420ee780270ca6d993d18d4101049d0`: complete upstream `pinyin_simp.dict.yaml`, derived from Android PinyinIME. Apache-2.0 license in `Licenses/pinyin-simp.txt`.
- `schemas/inkflow_pinyin.schema.yaml` adapts the upstream schema for one full-pinyin mode. Stroke reverse lookup and external symbol presets are omitted; punctuation and paging bindings are explicit. The dictionary is copied unmodified.

The native app targets this Apple Silicon Mac. Its minimum deployment target is macOS 13. Build uses the current Xcode SDK, ARC, and warnings as errors. InputMethodKit controls the candidate UI. Each controller owns one Rime session, and the process initializes/deploys the engine on the main thread before serving input. Deployment and user dictionaries are writable only in Application Support/InkFlow. Routine logs omit input text.

The app icon is built from the approved inkstone and brush artwork in `Design/AppIcon`; see its README for source and export roles. The menu icon uses Ink lettering in Futura Bold in `Resources/MenuIconTemplate.tiff`, with 1x/2x representations; its generator and design notes live in `Design/MenuIcon`. Parent input-source and palette icons still use the local macOS CoreTypes generic application icon. The bundle identifier includes `.inputmethod.` for macOS input method discovery/launch compatibility. `register.sh` verifies TIS registration after installation without enabling or selecting the input source.

A single explicit `.Hans` input mode exposes the existing simplified pinyin engine to system settings. Its name is localized through `InfoPlist.strings`. Registration first informs Launch Services, then TIS, and requires a named/select-capable keyboard mode. A separate `--verify-enabled` invocation reads the parent and mode enabled states; registration never enables or selects a source. Mode metadata follows Apple's TN2128 and the current TextInputSources/TextServices SDK headers.
