#!/bin/zsh -f
set -euo pipefail

verify_host_path=/usr/bin:/bin:/usr/sbin:/sbin
export PATH="$verify_host_path"
unset \
  BASH_ENV BUNDLE_GEMFILE CDPATH ENV GEM_HOME GEM_PATH \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL \
  GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_DIR GIT_EXEC_PATH \
  GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_WORK_TREE \
  GREP_OPTIONS PERL5LIB PERL5OPT PERLLIB RIPGREP_CONFIG_PATH RUBYLIB RUBYOPT \
  UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT \
  ZDOTDIR

verify_script_dir=${0:A:h}
verify_repo_root=${verify_script_dir:h:h}
verify_android_dir="$verify_repo_root/platforms/android"
verify_app_dir="$verify_android_dir/app"
verify_gradle="$verify_android_dir/gradlew"
verify_gradle_user_home="$verify_repo_root/build/gradle-user-home"
verify_sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
if [[ -z "$verify_sdk" && -d "$HOME/Library/Android/sdk" ]]; then
  verify_sdk="$HOME/Library/Android/sdk"
fi

fail() {
  print -u2 "error: $1"
  exit 1
}

[[ ! -L "$verify_repo_root/build" ]] || \
  fail "repository build directory must not be a symbolic link"
verify_validator_home="$verify_repo_root/build/verification-home"
[[ ! -L "$verify_validator_home" ]] || \
  fail "verification home must not be a symbolic link"
case "$verify_validator_home" in
  "$verify_repo_root/build/verification-home")
    /bin/rm -rf -- "$verify_validator_home"
    /bin/mkdir -p "$verify_validator_home"
    ;;
  *)
    fail "refusing to initialize unexpected verification home"
    ;;
esac

verify_ruby() {
  /usr/bin/env -i \
    "HOME=$verify_validator_home" \
    "PATH=$verify_host_path" \
    "TMPDIR=/private/tmp" \
    "LANG=en_US.UTF-8" \
    "GIT_CONFIG_NOSYSTEM=1" \
    "GIT_CONFIG_GLOBAL=/dev/null" \
    "GIT_CONFIG_COUNT=2" \
    "GIT_CONFIG_KEY_0=core.fsmonitor" \
    "GIT_CONFIG_VALUE_0=false" \
    "GIT_CONFIG_KEY_1=core.hooksPath" \
    "GIT_CONFIG_VALUE_1=/dev/null" \
    "GIT_OPTIONAL_LOCKS=0" \
    /usr/bin/ruby "$@"
}

verify_grep() {
  /usr/bin/env -i \
    "PATH=$verify_host_path" \
    "LC_ALL=C" \
    /usr/bin/grep "$@"
}

verify_sha256() {
  verify_ruby -rdigest -e '
    abort "usage: sha256 FILE" unless ARGV.length == 1
    puts Digest::SHA256.file(ARGV.fetch(0)).hexdigest
  ' "$@"
}

verify_unzip() {
  /usr/bin/env -i \
    "PATH=$verify_host_path" \
    "LC_ALL=C" \
    /usr/bin/unzip "$@"
}

run_isolated_java_tool() {
  /usr/bin/env -i \
    "HOME=$verify_validator_home" \
    "PATH=$verify_gradle_path" \
    "TMPDIR=/private/tmp" \
    "LANG=en_US.UTF-8" \
    "JAVA_HOME=$verify_java_home" \
    "$@"
}

if (( $# > 1 )); then
  fail "usage: $0"
elif (( $# == 1 )) && [[ $1 != --host-isolation-probe ]]; then
  fail "usage: $0"
fi

verify_gradle_distribution_tree() {
  local -a verify_gradle_distribution_trees
  verify_gradle_distribution_trees=(
    "$verify_gradle_distribution_parent"/*/"gradle-$verify_gradle_version"(N)
  )
  (( ${#verify_gradle_distribution_trees} == 1 )) || \
    fail "expected exactly one extracted Gradle $verify_gradle_version distribution"
  local verify_gradle_distribution_path=${verify_gradle_distribution_trees[1]}
  [[ -d "$verify_gradle_distribution_path" && \
    ! -L "$verify_gradle_distribution_path" ]] || \
    fail "extracted Gradle distribution must be a real directory"
  verify_ruby "$verify_script_dir/check_source_tree.rb" \
    "$verify_gradle_distribution_path" "$verify_gradle_distribution_digest"
}

run_locked_gradle() {
  verify_ruby "$verify_script_dir/check_android_native_inputs.rb" settings \
    "$verify_repo_root"
  verify_ruby "$verify_script_dir/check_dependency_lock.rb"

  local verify_forbidden_gradle_input
  for verify_forbidden_gradle_input in \
    "$verify_gradle_user_home/gradle.properties" \
    "$verify_gradle_user_home/init.gradle" \
    "$verify_gradle_user_home/init.gradle.kts" \
    "$verify_gradle_user_home/init.d"; do
    [[ ! -e "$verify_forbidden_gradle_input" ]] || \
      fail "isolated Gradle user home contains forbidden configuration: $verify_forbidden_gradle_input"
  done

  local -a verify_gradle_environment
  verify_gradle_environment=(
    "HOME=$verify_validator_home"
    "PATH=$verify_gradle_path"
    "TMPDIR=$verify_tmp_dir/gradle-tmp"
    "LANG=en_US.UTF-8"
    "ANDROID_SDK_ROOT=$verify_sdk"
    "GRADLE_USER_HOME=$verify_gradle_user_home"
    "JAVA_HOME=$verify_java_home"
    "PYTHONNOUSERSITE=1"
  )
  if [[ -n ${ANDROID_SERIAL:-} ]]; then
    verify_gradle_environment+=("ANDROID_SERIAL=$ANDROID_SERIAL")
  fi

  if [[ "$verify_gradle_distribution_bootstrap" == false ]]; then
    verify_gradle_distribution_tree
  fi

  local verify_gradle_status=0
  /usr/bin/env -i "${verify_gradle_environment[@]}" \
    "$verify_gradle" --no-build-cache --no-configuration-cache "$@" || \
    verify_gradle_status=$?
  verify_gradle_distribution_tree
  verify_ruby "$verify_script_dir/check_dependency_lock.rb"
  verify_gradle_distribution_bootstrap=false
  return "$verify_gradle_status"
}

for command in cmp diff find grep mkdir rm unzip; do
  command -v "$command" >/dev/null || fail "required command not found: $command"
done
[[ ! -L "$verify_gradle_user_home" ]] || \
  fail "isolated Gradle user home must not be a symbolic link"
mkdir -p "$verify_gradle_user_home"

verify_toolchain_lock="$verify_repo_root/toolchains.lock.json"
verify_dependency_lock="$verify_repo_root/dependencies.lock.json"
verify_version_catalog="$verify_android_dir/gradle/libs.versions.toml"
verify_gradle_version=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("gradleVersion")
' "$verify_toolchain_lock")
verify_gradle_distribution_digest=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("gradleDistributionTreeSha256")
' "$verify_toolchain_lock")
verify_native_build_python_relative=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("nativeBuildPython")
' "$verify_toolchain_lock")
[[ "$verify_native_build_python_relative" == tools/build/python-isolated ]] || \
  fail "native-build Python launcher must use the repository-owned path"
verify_native_build_python="$verify_repo_root/$verify_native_build_python_relative"
verify_native_build_python_digest=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("nativeBuildPythonSha256")
' "$verify_toolchain_lock")
verify_native_build_python_interpreter=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("nativeBuildPythonInterpreter")
' "$verify_toolchain_lock")
[[ "$verify_native_build_python_interpreter" == /usr/bin/python3 ]] || \
  fail "native-build Python interpreter must be /usr/bin/python3"
verify_gradle_distribution_parent="$verify_gradle_user_home/wrapper/dists/gradle-$verify_gradle_version-bin"
verify_gradle_distribution_bootstrap=false
verify_gradle_path=$verify_host_path
verify_java_major=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("host").fetch("java").fetch("requiredMajorVersion")
' "$verify_toolchain_lock")
verify_java_home=$(/usr/libexec/java_home -v "$verify_java_major")
if [[ ${1:-} == --host-isolation-probe ]]; then
  [[ $(command -v env) == /usr/bin/env ]] || \
    fail "host-isolation probe resolved an unexpected env command"
  [[ $(command -v git) == /usr/bin/git ]] || \
    fail "host-isolation probe resolved an unexpected git command"
  [[ $(command -v grep) == /usr/bin/grep ]] || \
    fail "host-isolation probe resolved an unexpected grep command"
  [[ $(command -v ruby) == /usr/bin/ruby ]] || \
    fail "host-isolation probe resolved an unexpected ruby command"
  printf '%s\n' inkflow-match | verify_grep -Fq -- inkflow-match || \
    fail "isolated grep rejected an expected match"
  if printf '%s\n' inkflow-safe | verify_grep -Fq -- inkflow-forbidden; then
    fail "isolated grep accepted a missing match"
  fi
  verify_digest_probe="$verify_validator_home/sha256-probe"
  printf '%s\n' inkflow > "$verify_digest_probe"
  [[ $(verify_sha256 "$verify_digest_probe") == \
    2bc9621bc44ac4e5767f7af8cf8fdb391511f307bc7d17b1fbcaec51aa040206 ]] || \
    fail "isolated SHA-256 verifier returned an unexpected digest"
  /bin/rm -f -- "$verify_digest_probe"
  verify_unzip -Z1 \
    "$verify_android_dir/gradle/wrapper/gradle-wrapper.jar" | \
    verify_grep -Fxq -- 'org/gradle/wrapper/GradleWrapperMain.class' || \
    fail "isolated ZIP verifier omitted the Gradle wrapper entry"
  verify_ruby -ropen3 -rrubygems -e '
    forbidden = %w[BUNDLE_GEMFILE GEM_HOME GEM_PATH RUBYLIB RUBYOPT]
    abort "Ruby environment was not isolated" unless forbidden.none? { |name| ENV.key?(name) }
    abort "Git system config was not disabled" unless ENV["GIT_CONFIG_NOSYSTEM"] == "1"
    abort "Git global config was not disabled" unless ENV["GIT_CONFIG_GLOBAL"] == "/dev/null"
    abort "Unexpected Git system config override" if ENV.key?("GIT_CONFIG_SYSTEM")
    abort "Git command overrides are incomplete" unless ENV["GIT_CONFIG_COUNT"] == "2"
    abort "Optional Git writes were not disabled" unless ENV["GIT_OPTIONAL_LOCKS"] == "0"
    Gem.load_plugins
    _output, status = Open3.capture2e(
      "git", "-C", ARGV.fetch(0), "status", "--porcelain=v1", "--untracked-files=no"
    )
    abort "isolated Git status failed" unless status.success?
  ' "$verify_repo_root"
  run_isolated_java_tool /usr/bin/ruby -e '
    forbidden = %w[
      APKANALYZER_OPTS JAVA_OPTS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS
    ]
    abort "Java tool environment was not isolated" unless forbidden.none? { |name| ENV.key?(name) }
    abort "Java tool did not receive the locked JAVA_HOME" unless ENV["JAVA_HOME"] == ARGV.fetch(0)
  ' "$verify_java_home"
  /bin/rm -rf -- "$verify_validator_home"
  print "PASS Android verification host is isolated"
  exit 0
fi
[[ -n "$verify_sdk" ]] || fail "ANDROID_HOME or ANDROID_SDK_ROOT is not set"
verify_agp_version=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("androidGradlePluginVersion")
' "$verify_toolchain_lock")
verify_compile_sdk=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("compileSdk")
' "$verify_toolchain_lock")
verify_min_sdk=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("minSdk")
' "$verify_toolchain_lock")
verify_ndk_version=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("ndkVersion")
' "$verify_toolchain_lock")
verify_cmake_version=$(verify_ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("android").fetch("cmakeVersion")
' "$verify_toolchain_lock")
verify_ninja="$verify_sdk/cmake/$verify_cmake_version/bin/ninja"
verify_boost_cache_key=$(verify_ruby -rjson -e '
  boost = JSON.parse(File.read(ARGV.fetch(0))).fetch("dependencies").fetch("boost")
  print "boost-#{boost.fetch("version")}-#{boost.fetch("sha256")}"
' "$verify_dependency_lock")
verify_boost_source_cache="$verify_repo_root/build/dependencies/sources/$verify_boost_cache_key"
verify_boost_ready_marker="$verify_repo_root/build/dependencies/ready/$verify_boost_cache_key.sha256"
verify_boost_cache_preexisting=false
if [[ -d "$verify_boost_source_cache" && -f "$verify_boost_ready_marker" ]]; then
  verify_boost_cache_preexisting=true
fi

verify_apkanalyzer="$verify_sdk/cmdline-tools/latest/bin/apkanalyzer"
verify_adb="$verify_sdk/platform-tools/adb"
verify_aapt2_candidates=("$verify_sdk/build-tools/${verify_compile_sdk}"*/aapt2(N))
(( ${#verify_aapt2_candidates} > 0 )) || \
  fail "Android SDK Build Tools for API $verify_compile_sdk are missing"
verify_aapt2=${verify_aapt2_candidates[-1]}
verify_llvm_bin="$verify_sdk/ndk/$verify_ndk_version/toolchains/llvm/prebuilt/darwin-x86_64/bin"
verify_nm="$verify_llvm_bin/llvm-nm"
verify_readobj="$verify_llvm_bin/llvm-readobj"
for executable in \
  "$verify_gradle" \
  "$verify_adb" \
  "$verify_apkanalyzer" \
  "$verify_aapt2" \
  "$verify_nm" \
  "$verify_readobj" \
  "$verify_ninja" \
  "$verify_native_build_python" \
  "$verify_native_build_python_interpreter" \
  "$verify_java_home/bin/java"; do
  [[ -x "$executable" ]] || fail "required executable is missing: $executable"
done

verify_tmp_parent=/private/tmp
verify_tmp_dir=$(mktemp -d "${verify_tmp_parent%/}/inkflow-android.XXXXXX")
mkdir -p "$verify_tmp_dir/gradle-tmp"
cleanup() {
  case "$verify_tmp_dir" in
    "${verify_tmp_parent%/}"/inkflow-android.*)
      rm -rf -- "$verify_tmp_dir"
      ;;
    *)
      print -u2 "warning: refusing to clean unexpected path: $verify_tmp_dir"
      ;;
  esac
  case "$verify_validator_home" in
    "$verify_repo_root/build/verification-home")
      rm -rf -- "$verify_validator_home"
      ;;
    *)
      print -u2 "warning: refusing to clean unexpected verification home"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

print "Verifying locked Android build metadata..."
verify_ruby "$verify_script_dir/test/check_gradle_version_test.rb"
verify_ruby "$verify_script_dir/test/check_android_build_contract_test.rb"
verify_ruby "$verify_script_dir/test/check_android_native_inputs_test.rb"
verify_ruby "$verify_script_dir/test/check_elf_needed_libraries_test.rb"
verify_ruby "$verify_script_dir/test/check_git_worktree_test.rb"
verify_ruby "$verify_script_dir/test/check_native_path_strings_test.rb"
verify_ruby "$verify_script_dir/test/check_source_tree_test.rb"
verify_ruby "$verify_script_dir/test/python_isolated_test.rb"
verify_ruby "$verify_script_dir/test/android_host_isolation_test.rb"
verify_ruby "$verify_script_dir/check_dependency_lock.rb"
verify_ruby "$verify_script_dir/check_android_build_contract.rb" catalog \
  "$verify_toolchain_lock" "$verify_version_catalog"
[[ $(verify_sha256 "$verify_android_dir/gradle/wrapper/gradle-wrapper.jar") == \
  b3a875ddc1f044746e1b1a55f645584505f4a10438c1afea9f15e92a7c42ec13 ]] || \
  fail "Gradle wrapper JAR checksum differs from the official 9.3.1 wrapper"
verify_grep -Fq -- "distributionUrl=https\\://services.gradle.org/distributions/gradle-$verify_gradle_version-bin.zip" \
  "$verify_android_dir/gradle/wrapper/gradle-wrapper.properties" || \
  fail "Gradle wrapper distribution is not $verify_gradle_version-bin"
verify_grep -Eq -- '^distributionSha256Sum=b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06$' \
  "$verify_android_dir/gradle/wrapper/gradle-wrapper.properties" || \
  fail "Gradle wrapper distribution checksum is not locked"
verify_grep -Fq -- '<verify-metadata>true</verify-metadata>' \
  "$verify_android_dir/gradle/verification-metadata.xml" || \
  fail "Gradle dependency verification metadata is missing"
verify_grep -Fq -- "<component group=\"com.android.application\" name=\"com.android.application.gradle.plugin\" version=\"$verify_agp_version\">" \
  "$verify_android_dir/gradle/verification-metadata.xml" || \
  fail "AGP plugin marker $verify_agp_version is missing from dependency verification metadata"
verify_grep -Fq -- "<component group=\"com.android.tools.build\" name=\"gradle\" version=\"$verify_agp_version\">" \
  "$verify_android_dir/gradle/verification-metadata.xml" || \
  fail "AGP artifact $verify_agp_version is missing from dependency verification metadata"
[[ $(verify_sha256 "$verify_native_build_python") == \
  "$verify_native_build_python_digest" ]] || \
  fail "native-build Python launcher checksum differs from toolchains.lock.json"

for verify_gradle_distribution_component in \
  "$verify_gradle_user_home/wrapper" \
  "$verify_gradle_user_home/wrapper/dists" \
  "$verify_gradle_distribution_parent"; do
  [[ ! -L "$verify_gradle_distribution_component" ]] || \
    fail "Gradle distribution cache path must not be a symbolic link: $verify_gradle_distribution_component"
done
verify_gradle_distribution_trees=(
  "$verify_gradle_distribution_parent"/*/"gradle-$verify_gradle_version"(N)
)
if (( ${#verify_gradle_distribution_trees} == 0 )); then
  case "$verify_gradle_distribution_parent" in
    "$verify_repo_root/build/gradle-user-home/wrapper/dists/gradle-$verify_gradle_version-bin")
      rm -rf -- "$verify_gradle_distribution_parent"
      ;;
    *)
      fail "refusing to clear unexpected Gradle distribution cache path"
      ;;
  esac
  verify_gradle_distribution_bootstrap=true
elif (( ${#verify_gradle_distribution_trees} == 1 )); then
  verify_gradle_distribution_tree
else
  fail "multiple extracted Gradle $verify_gradle_version distributions found"
fi

verify_gradle_output=$(run_locked_gradle --version)
printf '%s\n' "$verify_gradle_output" | \
  verify_ruby "$verify_script_dir/check_gradle_version.rb" \
    "$verify_gradle_version" "$verify_java_major"
[[ -d "$verify_sdk/platforms/android-$verify_compile_sdk" ]] || \
  fail "Android SDK Platform $verify_compile_sdk is missing"
[[ -d "$verify_sdk/ndk/$verify_ndk_version" ]] || \
  fail "Android NDK $verify_ndk_version is missing"
[[ -d "$verify_sdk/cmake/$verify_cmake_version" ]] || \
  fail "Android CMake $verify_cmake_version is missing"
verify_gradle_scripts=(
  "$verify_android_dir"/**/*.gradle(.N)
  "$verify_android_dir"/**/*.gradle.kts(.N)
)
if (( ${#verify_gradle_scripts} > 0 )) && \
    verify_grep -En -- 'org\.jetbrains\.kotlin|kotlin\("android"\)' \
      "${verify_gradle_scripts[@]}"; then
  fail "AGP 9 built-in Kotlin must not be shadowed by the Kotlin Gradle plugin"
fi
print "PASS locked Gradle launcher JVM, exact catalog, AGP built-in Kotlin, SDK, NDK, CMake, and dependency checks"

print "Verifying source privacy and canonical schema boundaries..."
[[ ! -e "$verify_app_dir/src/main/assets" ]] || \
  fail "app/src/main/assets must not duplicate canonical schemas"
verify_schema_inventory="$verify_tmp_dir/schema-source"
find "$verify_repo_root/schemas/source" -maxdepth 1 -type f -exec basename {} \; | \
  LC_ALL=C sort > "$verify_schema_inventory"
diff -u <(printf '%s\n' default.yaml inkflow.dict.yaml inkflow.schema.yaml) \
  "$verify_schema_inventory"
if verify_grep -ERn -- \
  'android\.util\.Log|System\.(out|err)|(^|[^[:alnum:]_])print(ln)?[[:space:]]*\(|(^|[^[:alnum:]_])(printf|fprintf|puts|fputs)[[:space:]]*\(|std::(cout|cerr|clog)' \
  "$verify_app_dir/src/main/kotlin" "$verify_app_dir/src/main/cpp" \
  "$verify_repo_root/engine/src"; then
  fail "Android product source contains a logging or console-output API"
fi
if verify_grep -ERn -- 'NewStringUTF' "$verify_app_dir/src/main/cpp"; then
  fail "JNI product text must use strict UTF-8 decoding and NewString"
fi
if verify_grep -ERn -- 'deleteSurroundingText(InCodePoints)?' \
  "$verify_app_dir/src/main/kotlin"; then
  fail "Android backspace must use selection-aware DEL key events"
fi
if verify_grep -ERn -- \
  'get(SelectedText|TextBeforeCursor|TextAfterCursor|SurroundingText)\(' \
  "$verify_app_dir/src/main/kotlin"; then
  fail "Android product source must not read selected or surrounding editor text"
fi
if verify_grep -ERn -- 'getExtractedText\(' \
  "$verify_app_dir/src/main/kotlin"; then
  fail "Android product source must not read extracted editor text"
fi
verify_grep -Fq -- 'RegisterNatives' \
  "$verify_app_dir/src/main/cpp/jni_bridge.cpp" || \
  fail "JNI bridge does not use RegisterNatives"
verify_grep -Fq -- 'JNI_OnLoad' \
  "$verify_app_dir/src/main/cpp/jni_bridge.cpp" || \
  fail "JNI bridge does not expose JNI_OnLoad"
verify_grep -Fq -- 'if (!editorActive || editorSensitive)' \
  "$verify_app_dir/src/main/kotlin/io/damao/inkflow/ime/InkFlowInputMethodService.kt" || \
  fail "sensitive editors do not bypass selection callback handling"
verify_grep -Fq -- 'sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)' \
  "$verify_app_dir/src/main/kotlin/io/damao/inkflow/ime/InkFlowInputMethodService.kt" || \
  fail "Android backspace does not use the standard DEL key-event path"
verify_grep -Fq -- 'trackSelection = false' \
  "$verify_app_dir/src/main/kotlin/io/damao/inkflow/ime/InkFlowInputMethodService.kt" || \
  fail "sensitive direct input is not isolated from selection tracking"
verify_grep -Fq -- 'worker = InkFlowEngineProcess.executor' \
  "$verify_app_dir/src/main/kotlin/io/damao/inkflow/ime/InkFlowInputMethodService.kt" || \
  fail "IME services do not share the process engine queue"
if verify_grep -ERn -- '\.shutdown(Now)?\(' \
  "$verify_app_dir/src/main/kotlin"; then
  fail "the process engine queue must live for the process lifetime"
fi

verify_jni_bridge="$verify_app_dir/src/main/cpp/jni_bridge.cpp"
for jni_descriptor in \
  '"()J"' \
  '"(J)Z"' \
  '"(JII)Lio/damao/inkflow/engine/NativeEngineUpdate;"' \
  '"(J)Lio/damao/inkflow/engine/NativeEngineUpdate;"' \
  '"(JI)Lio/damao/inkflow/engine/NativeEngineUpdate;"' \
  '"(JZ)Lio/damao/inkflow/engine/NativeEngineUpdate;"'; do
  verify_grep -Fq -- "$jni_descriptor" "$verify_jni_bridge" || \
    fail "JNI owner-token descriptor is missing: $jni_descriptor"
done
verify_grep -Fq -- 'owner_token != g_session_owner' "$verify_jni_bridge" || \
  fail "JNI operations do not validate their session owner token"
print "PASS canonical privacy boundary, selection-aware DEL, process queue, strict UTF-8, and JNI owner signatures"

print "Removing generated Android state for a clean native rebuild..."
for verify_generated_dir in \
  "$verify_android_dir/.gradle" \
  "$verify_app_dir/.cxx" \
  "$verify_app_dir/build"; do
  case "$verify_generated_dir" in
    "$verify_repo_root/platforms/android/.gradle"|\
    "$verify_repo_root/platforms/android/app/.cxx"|\
    "$verify_repo_root/platforms/android/app/build")
      rm -rf -- "$verify_generated_dir"
      ;;
    *)
      fail "refusing to remove unexpected generated path: $verify_generated_dir"
      ;;
  esac
done

print "Running JVM tests and building debug, test, and R8 release APKs..."
run_locked_gradle -p "$verify_android_dir" --no-daemon \
  "-PinkflowExpectedJavaMajor=$verify_java_major" \
  verifyBuildJvm testDebugUnitTest assembleDebug assembleDebugAndroidTest assembleRelease

verify_debug_apk="$verify_app_dir/build/outputs/apk/debug/app-debug.apk"
verify_test_apk="$verify_app_dir/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
verify_release_apk="$verify_app_dir/build/outputs/apk/release/app-release-unsigned.apk"
for artifact in "$verify_debug_apk" "$verify_test_apk" "$verify_release_apk"; do
  [[ -s "$artifact" ]] || fail "missing APK: $artifact"
done
print "PASS locked Gradle build JVM, JVM tests, and all APK builds"

if [[ "$verify_boost_cache_preexisting" == false ]]; then
  print "Verifying the newly populated Boost source cache..."
  [[ -d "$verify_boost_source_cache" && -f "$verify_boost_ready_marker" ]] || \
    fail "Gradle native build did not populate the locked Boost source cache"
  verify_ruby "$verify_script_dir/check_dependency_lock.rb"
fi

print "Auditing manifests, assets, ABI, JNI exports, and R8 output..."
verify_manifest="$verify_tmp_dir/manifest.xml"
run_isolated_java_tool "$verify_apkanalyzer" manifest print \
  "$verify_release_apk" > "$verify_manifest"
verify_input_method_path=$(run_isolated_java_tool "$verify_apkanalyzer" resources value \
  --config default --type xml --name input_method "$verify_release_apk")
[[ "$verify_input_method_path" == res/*.xml ]] || \
  fail "packaged input_method resource did not resolve to an XML path"
verify_input_method_xml="$verify_tmp_dir/input-method.xml"
run_isolated_java_tool "$verify_apkanalyzer" resources xml \
  --file "$verify_input_method_path" \
  "$verify_release_apk" > "$verify_input_method_xml"
verify_data_extraction_rules_path=$(run_isolated_java_tool "$verify_apkanalyzer" resources value \
  --config default --type xml --name data_extraction_rules "$verify_release_apk")
[[ "$verify_data_extraction_rules_path" == res/*.xml ]] || \
  fail "packaged data_extraction_rules resource did not resolve to an XML path"
verify_data_extraction_rules_xml="$verify_tmp_dir/data-extraction-rules.xml"
run_isolated_java_tool "$verify_apkanalyzer" resources xml \
  --file "$verify_data_extraction_rules_path" \
  "$verify_release_apk" > "$verify_data_extraction_rules_xml"
verify_resource_table="$verify_tmp_dir/resources.txt"
"$verify_aapt2" dump resources "$verify_release_apk" > "$verify_resource_table"

verify_app_metadata="$verify_tmp_dir/app-metadata.properties"
verify_unzip -p "$verify_release_apk" \
  META-INF/com/android/build/gradle/app-metadata.properties > "$verify_app_metadata"
[[ -s "$verify_app_metadata" ]] || fail "release APK is missing AGP app metadata"

verify_active_compile_commands="$verify_app_dir/.cxx/tools/release/arm64-v8a/compile_commands.json"
[[ -s "$verify_active_compile_commands" ]] || \
  fail "active release arm64-v8a CXX compilation database is missing"
verify_cxx_build_dir=$(verify_ruby -rjson -e '
  directories = JSON.parse(File.read(ARGV.fetch(0))).map { |entry| entry.fetch("directory") }.uniq
  abort "active CXX compilation database has no unique build directory" unless directories.length == 1
  print directories.fetch(0)
' "$verify_active_compile_commands")
case "$verify_cxx_build_dir" in
  "$verify_app_dir/.cxx/RelWithDebInfo/"*/arm64-v8a)
    ;;
  *)
    fail "active CXX compilation database points outside the release arm64-v8a model"
    ;;
esac
verify_cxx_hash=${verify_cxx_build_dir:h:t}
verify_cxx_model="$verify_app_dir/build/intermediates/cxx/RelWithDebInfo/$verify_cxx_hash/logs/arm64-v8a/build_model.json"
[[ -s "$verify_cxx_model" ]] || fail "active release CXX build model is missing"
verify_cmake_cache="$verify_cxx_build_dir/CMakeCache.txt"
[[ -s "$verify_cmake_cache" ]] || fail "active release CMake cache is missing"
verify_cmake_indices=("$verify_cxx_build_dir"/.cmake/api/v1/reply/index-*.json(N))
(( ${#verify_cmake_indices} > 0 )) || fail "active CMake File API index is missing"
verify_cmake_index=${verify_cmake_indices[-1]}
verify_ninja_deps="$verify_tmp_dir/ninja-deps.txt"
"$verify_ninja" -C "$verify_cxx_build_dir" -t deps > "$verify_ninja_deps"
[[ -s "$verify_ninja_deps" ]] || fail "active release Ninja dependency graph is missing"

verify_ruby "$verify_script_dir/check_android_native_inputs.rb" \
  "$verify_cxx_model" "$verify_cmake_cache" "$verify_active_compile_commands" \
  "$verify_ninja_deps" \
  "$verify_repo_root/build/dependencies" "$verify_boost_source_cache" \
  "$verify_repo_root" "$verify_sdk" "$verify_ndk_version" \
  "$verify_cmake_version" "$verify_min_sdk" "$verify_native_build_python"

verify_ruby "$verify_script_dir/check_android_build_contract.rb" artifacts \
  "$verify_toolchain_lock" "$verify_app_metadata" "$verify_cxx_model" \
  "$verify_cmake_index" "$verify_manifest" "$verify_resource_table" \
  "$verify_input_method_path" "$verify_input_method_xml" \
  "$verify_data_extraction_rules_path" "$verify_data_extraction_rules_xml"

for apk in "$verify_debug_apk" "$verify_release_apk"; do
  verify_apk_name=${apk:t}
  verify_unzip -Z1 "$apk" | verify_grep -E '^assets/' | LC_ALL=C sort > \
    "$verify_tmp_dir/$verify_apk_name.assets"
  diff -u \
    <(printf '%s\n' \
      assets/inkflow-schema/default.yaml \
      assets/inkflow-schema/inkflow.dict.yaml \
      assets/inkflow-schema/inkflow.schema.yaml) \
    "$verify_tmp_dir/$verify_apk_name.assets"
  verify_unzip -Z1 "$apk" | verify_grep -E '^lib/' | LC_ALL=C sort > \
    "$verify_tmp_dir/$verify_apk_name.libs"
  diff -u <(printf '%s\n' lib/arm64-v8a/libinkflow_android.so) \
    "$verify_tmp_dir/$verify_apk_name.libs"
  for schema in default.yaml inkflow.dict.yaml inkflow.schema.yaml; do
    verify_unzip -p "$apk" "assets/inkflow-schema/$schema" > \
      "$verify_tmp_dir/$verify_apk_name.$schema"
    cmp "$verify_repo_root/schemas/source/$schema" \
      "$verify_tmp_dir/$verify_apk_name.$schema"
  done
done

verify_native_library="$verify_tmp_dir/release-libinkflow_android.so"
verify_unzip -p "$verify_release_apk" \
  lib/arm64-v8a/libinkflow_android.so > "$verify_native_library"
[[ -s "$verify_native_library" ]] || fail "packaged release JNI library is missing"
"$verify_nm" -D --defined-only "$verify_native_library" | awk '{print $3}' | \
  LC_ALL=C sort > "$verify_tmp_dir/native-exports"
{
  print JNI_OnLoad
  cat "$verify_repo_root/engine/exports/inkflow_engine.symbols"
} | LC_ALL=C sort > "$verify_tmp_dir/expected-exports"
diff -u "$verify_tmp_dir/expected-exports" "$verify_tmp_dir/native-exports"

"$verify_readobj" --needed-libs "$verify_native_library" | \
  verify_ruby "$verify_script_dir/check_elf_needed_libraries.rb" \
    libc.so libdl.so libm.so
"$verify_readobj" --file-headers "$verify_native_library" | \
  verify_grep -Fq -- 'Machine: EM_AARCH64'
verify_ruby "$verify_script_dir/check_native_path_strings.rb" \
  "$verify_native_library" "$verify_repo_root" "$verify_sdk"

verify_mapping="$verify_app_dir/build/outputs/mapping/release/mapping.txt"
for kept_class in \
  io.damao.inkflow.engine.NativeBridge \
  io.damao.inkflow.engine.NativeEngineUpdate \
  io.damao.inkflow.engine.EngineCandidate; do
  verify_grep -Fxq -- "${kept_class} -> ${kept_class}:" \
    "$verify_mapping" || \
    fail "R8 renamed JNI class: $kept_class"
done
run_isolated_java_tool "$verify_apkanalyzer" dex packages \
  "$verify_release_apk" > \
  "$verify_tmp_dir/release-dex-packages"
verify_grep -Fq -- 'NativeBridge int apiVersion()' \
  "$verify_tmp_dir/release-dex-packages" || \
  fail "R8 removed or renamed NativeBridge.apiVersion"
verify_grep -Fq -- \
  'NativeBridge void initialize(java.lang.String,java.lang.String,java.lang.String,java.lang.String)' \
  "$verify_tmp_dir/release-dex-packages" || \
  fail "R8 removed or renamed NativeBridge.initialize"
for bridge_method in \
  'NativeBridge long openSession()' \
  'NativeBridge boolean closeSession(long)' \
  'NativeBridge io.damao.inkflow.engine.NativeEngineUpdate processKey(long,int,int)' \
  'NativeBridge io.damao.inkflow.engine.NativeEngineUpdate commit(long)' \
  'NativeBridge io.damao.inkflow.engine.NativeEngineUpdate selectCandidate(long,int)' \
  'NativeBridge io.damao.inkflow.engine.NativeEngineUpdate changePage(long,boolean)' \
  'NativeBridge io.damao.inkflow.engine.NativeEngineUpdate reset(long)'; do
  verify_grep -Fq -- "$bridge_method" \
    "$verify_tmp_dir/release-dex-packages" || \
    fail "R8 removed or renamed owner-aware JNI method: $bridge_method"
done
for jni_constructor in \
  'NativeEngineUpdate <init>(boolean,java.lang.String,java.lang.String,long,long,long,java.util.List,long,boolean,boolean)' \
  'EngineCandidate <init>(java.lang.String,java.lang.String)'; do
  verify_grep -Fq -- "$jni_constructor" \
    "$verify_tmp_dir/release-dex-packages" || \
    fail "R8 removed or renamed JNI constructor: $jni_constructor"
done
print "PASS offline/privacy manifest, canonical assets, one arm64 JNI library, exact exports, system-only linkage, and R8 keep rules"

verify_device=""
verify_online_device_count=0
verify_adb_devices="$verify_tmp_dir/adb-devices"
"$verify_adb" devices > "$verify_adb_devices" || fail "adb devices failed"
while read -r verify_candidate verify_state; do
  [[ "$verify_state" == device ]] || continue
  verify_online_device_count=$((verify_online_device_count + 1))
  verify_candidate_abi=$(
    "$verify_adb" -s "$verify_candidate" shell getprop ro.product.cpu.abi | \
      tr -d '\r'
  )
  if [[ -z "$verify_device" && "$verify_candidate_abi" == arm64-v8a ]]; then
    verify_device="$verify_candidate"
  fi
done < "$verify_adb_devices"

if [[ -n "$verify_device" ]]; then
  ANDROID_SERIAL="$verify_device" \
    run_locked_gradle -p "$verify_android_dir" --no-daemon \
      "-PinkflowExpectedJavaMajor=$verify_java_major" \
      verifyBuildJvm connectedDebugAndroidTest
  print "PASS arm64 device/emulator JNI transcript ($verify_device)"
elif (( verify_online_device_count > 0 )); then
  print "SKIP instrumented JNI transcript (no online arm64-v8a target)"
else
  print "SKIP instrumented JNI transcript (no running device or emulator)"
fi

print "Android verification passed."
