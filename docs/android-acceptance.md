# Android acceptance contract

`tools/verify/android.sh` is the executable host gate for the native Android
input method. It uses the checked-in Gradle wrapper and dependency verification
metadata and performs the checks below without requiring a signing key.

## Toolchain and dependency integrity

- Require JDK 17, Gradle 9.3.1, AGP 9.1.1 built-in Kotlin, Android SDK 36,
  NDK 28.2.13676358, SDK CMake 3.22.1, and the repository-owned isolated
  Python launcher for OpenCC's build-time dictionary tools.
- Compare all six locked Android toolchain entries in the version catalog with
  `toolchains.lock.json`, and verify JDK 17 from the wrapper's reported
  Launcher JVM rather than `PATH`.
- Verify the official Gradle wrapper JAR and distribution ZIP SHA-256 values.
  On first use, accept only the Wrapper's checksum-verified extraction; before
  and after every later Gradle launch, verify the complete extracted
  distribution tree against `toolchains.lock.json`, including its own
  `init.d` directory.
- Resolve Gradle artifacts against checked-in SHA-256 verification metadata.
- Start the host gate with user zsh startup files disabled and a system-only
  tool path. Run every Ruby validator through `/usr/bin/ruby` in a clean
  environment with an empty verification home and safe Git configuration
  overrides. Run text matching, SHA-256, ZIP inspection, and Java-based SDK
  auditors in clean environments; Java tools also receive the locked JDK and
  no inherited JVM option variables. A negative probe proves its hostile PATH
  commands, `.zshenv`, Ruby, RubyGems and Perl hooks, Git fsmonitor hook,
  utility options, and Java option variables are all ineffective.
- Before and after every Gradle launch, verify the exact librime gitlink and a
  clean recursive checkout with no tracked, untracked, or ignored changes.
  Verify any tracked entry uses normal index state, rejecting
  `assume-unchanged` and `skip-worktree`. Verify any existing extracted Boost
  cache against the
  locale-independent source-tree SHA-256 in `dependencies.lock.json`; when the
  build creates that cache for the first time, the post-launch verification
  includes it immediately.
- Force the repository dependency cache into Gradle's native-build arguments,
  then require the active release CXX model, resolved CMake cache, and every
  InkFlow/librime compile command to use that same verified cache and Boost
  source tree. Reject any unexpected explicit include root, and audit Ninja's
  recorded dependencies so every Boost header actually consumed by a reused
  or fresh object came from the verified tree.
- Remove generated project, app, and CMake state before each acceptance build.
  Reject the ignored Android `local.properties` override. Run Gradle
  with build and configuration caches disabled, under a repository-owned
  Gradle user home that rejects user properties and init scripts, and under a
  minimal environment allowlist containing a fixed system-only path, home,
  temporary directory, locale, Android SDK, isolated Gradle home, a JDK 17 home
  selected by macOS, an optional device serial, and `PYTHONNOUSERSITE=1`. Pin
  OpenCC's build-time Python to a checksum-verified repository launcher that
  invokes `/usr/bin/python3 -I -S`; the launcher adds only the verified
  build-script directory after isolated startup so OpenCC's sibling imports
  still work. Require the active CXX model's complete native argument set,
  require its C and C++ flag lists to be empty, reject forced includes, and
  verify the explicitly empty compiler flags, linker flags, and launchers in
  the resolved CMake cache.
- Reject root-level `CMakeSettings.json` and `BuildSettings.json` before every
  Gradle launch. Verify the merged final CMake argument list and effective
  settings as closed sets, keep CMake preload/module/project/user-rules paths
  absent or empty, lock the CMake, Ninja, NDK toolchain, and compiler paths,
  and reject Ninja dependencies outside the repository or locked NDK.
- Verify AGP and SDK levels from the release APK, then verify the active
  release CXX model and CMake File API report the locked AGP, NDK, CMake,
  API-level, ABI, target, and static C++ runtime.
- Build only one application module and one `arm64-v8a` ABI with
  `c++_static`.

## JVM behavior

- Exercise the ordered `nihao -> 你好` key, candidate, and commit flow.
- Require editor start, close, reopen, key operations, finish, and UI delivery
  to obey one process-lifetime serialized queue and an editor-generation
  barrier. Destroying one service instance does not shut down that queue.
- Require a failed session open to fall back without sending the queued key to
  a not-ready engine.
- Reject a candidate or page token after a newer input operation has been
  queued, preventing an index from selecting a newer composition.
- Distinguish expected selection callbacks caused by InkFlow's own
  `InputConnection` writes from external cursor or selection changes using an
  exact old/new selection transition journal. It accepts either ordered
  callbacks or a final callback that collapses a known prefix. Unknown state
  fails closed; only one strictly matched composing-bounds/relative-UTF-16
  callback may establish a missing initial anchor. No editor text snapshot is
  read. External changes advance the editor generation, close and reopen the
  native session, and invalidate queued effects.
- Require candidate commits to replace the active composing region exactly
  once, and require an empty handled preedit to delete rather than finalize the
  previous composing text. An empty-string commit is permitted only after a
  successful InkFlow `setComposingText` in the same editor generation; editor
  switches, external selection recovery, finish, and failed connection writes
  revoke that permission. Therefore an empty-session failure or unhandled
  backspace cannot erase a host selection before applying its fallback.
- Send password-field backspace as the platform's standard software-keyboard
  DEL down/up pair. This delegates active-selection deletion to the editor
  without reading selected, surrounding, or extracted text.
- Route Return through Rime first. If Rime leaves it unhandled, invoke the
  editor's explicit custom action ID, the masked standard IME action, or a raw
  Enter down/up pair according to the captured `EditorInfo`. Honor
  `IME_FLAG_NO_ENTER_ACTION`, never turn a rejected action into an accidental
  newline, and journal the raw newline's selection transition before sending
  it.
- Bypass the engine for text password, visible password, web password, number
  password, and `IME_FLAG_NO_PERSONALIZED_LEARNING` editors. This direct path
  never reads extracted or surrounding text and never records input.
- Validate strict Unicode scalar boundaries and convert native UTF-8 byte
  offsets to Android UTF-16 offsets before an update reaches the UI.

## JNI and APK packaging

- Load one JNI library and register the kept Kotlin bridge from `JNI_OnLoad`.
- Give every opened native session a monotonically increasing owner token and
  validate it on close, key, commit, candidate, page, and reset operations. A
  stale owner close is a no-op and cannot close a replacement owner's session.
  Failure recovery may reopen only after closing a session that the failing
  backend still owned, so a stale operation cannot steal ownership back.
- Check the C API version independently before the real transcript in the
  instrumented test.
- Decode standard UTF-8 explicitly and create Java strings with `NewString`;
  `NewStringUTF` is forbidden because it accepts Modified UTF-8.
- Package the full static native closure into exactly
  `lib/arm64-v8a/libinkflow_android.so` and require its only public names to be
  `JNI_OnLoad` plus the 27 stable InkFlow C symbols.
- Require only Android system dynamic libraries (`libc`, `libdl`, and `libm`)
  and reject `libc++_shared` or a separate librime library.
- Run R8 for the unsigned release APK and require the JNI bridge and transfer
  object class names, constructors, and registered native method names to
  remain stable.

## Manifest, resources, and privacy

- Require the exact InkFlow service to be protected and exported, with its own
  `android.view.InputMethod` action and `android.view.im` metadata.
- Inspect the packaged input-method XML and require its `zh-Hans-CN` keyboard
  subtype and next-input-method switching declaration. The UI uses a
  native-View candidate strip with minimal letter and action keys. Android 9+
  uses the service API; Android 8.x uses the token-based platform fallback.
- Require no declared permissions, including `INTERNET` and
  `ACCESS_NETWORK_STATE`; require cleartext traffic to be disabled. Require
  `allowBackup=false` and `fullBackupContent=false` for Android 8.x through 11,
  plus a manifest-bound packaged `dataExtractionRules` resource for Android
  12+. Its cloud-backup and device-transfer sections must each contain exactly
  one path `.` exclusion for all nine supported storage domains, with no
  includes, extra nodes, qualified resource value, or qualified reference alias.
- Generate exactly three packaged schema assets from `schemas/source` and
  byte-compare them with the canonical files. Reject an editable
  `app/src/main/assets` copy.
- Reject Android logging and console-output APIs from product Kotlin and C++
  source, including the shared InkFlow engine compiled into the application.

## Optional arm64 runtime acceptance

The checked-in instrumented tests load the packaged JNI boundary, assert C API
version 1, deploy the bundled schema, prove that `A.open -> B.open -> A.close`
leaves B usable, enter `nihao`, select `你好`, and verify the committed
snapshot. They also exercise the candidate-replacement and empty-composition
contracts against `BaseInputConnection`. When an online arm64 device or
emulator is already connected, the verification script runs those tests.

For manual IME acceptance, build and install the debug APK, enable InkFlow in
Android's input-method settings, and verify the following in a host editor:

1. `nihao` displays `你好` and tapping it replaces the letters with exactly one
   `你好`; deleting the last preedit character leaves no finalized letter.
2. Backspace deletes an active host selection; space, return, candidate paging,
   and next-keyboard switching work.
3. Moving the host cursor clears stale candidates and restarts composition.
4. All four password variants and a no-personalized-learning editor remain
   direct-input only with an empty candidate strip.

## Evidence boundary

A passing host gate proves lock-to-catalog and built-artifact toolchain
agreement, locked dependency resolution, JVM behavior, Kotlin and native
compilation, unsigned APK creation, manifest and packaged-resource structure,
the JNI export and dynamic-link boundary, and R8 preservation. If no arm64
target is connected, it reports the instrumented transcript as skipped. It does
not prove installation, input-method enablement, host-app interaction,
physical-device behavior, signing, Play distribution, or publication.
The manifest settings and packaged deny-all rules establish the application's
requested platform backup policy. The host gate does not exercise a real
backup transport; manufacturer-specific behavior still requires device-level
verification.
