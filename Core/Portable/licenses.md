# Portable runtime distribution review

Packaging requirements and open rights questions for the pinned source build and the existing resource set (#34). Not legal clearance.

## Native code

Source revisions and archive hashes are in `native-sources.lock.json`. Paths below are relative to the extracted `build/portable/sources/` directory.

| Component | License and source notice | Distribution requirement |
| --- | --- | --- |
| librime 1.17.0 | BSD-3-Clause, `rime/LICENSE` | Retain copyright, conditions, and disclaimer in source and binary distributions. |
| librime-lua | BSD-3-Clause, `rime-lua/LICENSE` | Retain its separate notice, including when merged into librime. |
| Lua 5.4.8 | MIT, `lua/lua5.4/lua.h` | Include the copyright and permission notice. |
| Lua compatibility helpers | MIT notices in `rime-lua/src/lib/lauxlib-compat.c` and `lutf8lib-compat.c` | Preserve their notices when those helpers are included. |
| Boost 1.89.0 | Boost Software License 1.0, `boost/LICENSE_1_0.txt` | Retain the license with source; include it in product notices for the bundled headers/library. |
| glog | BSD-3-Clause, `glog/COPYING` | Include notice and disclaimer. |
| LevelDB | BSD-3-Clause, `leveldb/LICENSE` | Include notice and disclaimer. Optional Snappy/crc32c are disabled. |
| marisa | BSD-2-Clause **or** LGPL-2.1-or-later, `marisa/COPYING.md` | Use the BSD option and retain its notice. |
| yaml-cpp | MIT, `yaml/LICENSE` | Include copyright and permission notice. |
| OpenCC 1.1.9 and its standard conversion data | Apache-2.0, `opencc/LICENSE` | Include license and applicable notices; identify the C++17 build modification. |
| Darts-clone | BSD notice, `rime/include/COPYING.darts-clone`; OpenCC also vendors Darts-clone | Retain the corresponding notice for the embedded implementation. |
| UTF8-CPP | Boost Software License notice in `rime/include/utf8.h` and related headers | Preserve the notice with source. |
| RapidJSON | MIT notices in `opencc/deps/rapidjson-1.1.0/rapidjson/` | Include notices for the headers compiled into OpenCC. |
| TCLAP | MIT notice in `opencc/deps/tclap-1.2.5/tclap/CmdLine.h` | Required if shipping the OpenCC command-line tools built by this recipe. |

Only built components count; static linkage still requires attribution. A release package must collect notices from these pinned sources — `macOS/Licenses/` alone does not cover this runtime.

Linux builds use the system C/C++ runtime; an AppImage-style package that bundles it must review those libraries. The probe embeds checkout-local rpaths and is not distributable as is.

## Production dictionaries and other resources

The existing [dependency inventory](../../macOS/DEPENDENCIES.md), [Chinese dictionary notice](../../macOS/Licenses/chinese-dictionaries-NOTICE.txt), and [repository NOTICE](../../NOTICE) still apply. Compiling a dictionary does not remove source license obligations.

- rime-frost, rime-ice Chinese data, selected technical-English data, and emoji tables include GPL-3.0 material. The exact upstream inputs, modifications, license texts and recipe ship with every release as the dictionary source bundle (`macOS/scripts/dictionary-source-bundle.sh`, checked by `test.sh source-bundle`); the About page and README link to it.
- rime-easy-en is LGPL-3.0, with the incorporated GPL text. The unmodified archive and the filtering/weight-generation recipe are in the same bundle, with rebuild instructions, so users can modify and rebuild the shipped English data.
- The wordfreq-derived snapshot is CC BY-SA 4.0. Attribution, modifications and the adapted snapshot itself are in the bundle and `macOS/Licenses/wordfreq.txt`.
- The compatibility Pinyin source is Apache-2.0. OpenCC conversion resources also retain their Apache notices.
- No Sogou-derived catalog source remains since dictionary recipe 3; the former rime-selected conversion was removed rather than cleared. Fourteen curated terms in `Core/config/chinese-overrides.tsv` were first noticed in Sogou hotword lists but carry InkFlow text, readings and weights; the Chinese dictionary notice records that this is a project judgment, not a verified authorization.

## Channels

Direct Linux packages and notarized macOS downloads: the native licenses permit redistribution with notices, and the release attaches the dictionary source bundle. A portable build still has to collect the native-runtime notices above.

An iOS App Store keyboard needs a GPL/LGPL review against store terms before choosing its resource profile. Android and Windows reviews belong to their delivery phases.
