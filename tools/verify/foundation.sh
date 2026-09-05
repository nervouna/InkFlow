#!/bin/sh

set -eu

verify_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
verify_repo_root=$(CDPATH='' cd -- "${verify_script_dir}/../.." && pwd)
verify_mode="full"

if [ "${#}" -eq 1 ] && [ "${1}" = "--metadata-only" ]; then
  verify_mode="metadata-only"
elif [ "${#}" -ne 0 ]; then
  printf '%s\n' "usage: $0 [--metadata-only]" >&2
  exit 2
fi

verify_require_command() {
  if ! command -v "${1}" >/dev/null 2>&1; then
    printf '%s\n' "error: required command not found: ${1}" >&2
    exit 1
  fi
}

verify_require_command cmake
verify_require_command git
verify_require_command rg
verify_require_command ruby
verify_require_command xcodegen

printf '%s\n' "Verifying the foundation layout..."
for required_file in \
    ".editorconfig" \
    ".gitignore" \
    "CMakeLists.txt" \
    "CMakePresets.json" \
    "LICENSE" \
    "NOTICE.md" \
    "README.md" \
    "dependencies.lock.json" \
    "toolchains.lock.json" \
    "cmake/InkFlowPaths.cmake" \
    "platforms/apple/project.yml" \
    "platforms/android/settings.gradle.kts" \
    "platforms/android/gradle/libs.versions.toml" \
    "tools/build/python-isolated" \
    "tools/bootstrap/bootstrap.sh" \
    "tools/verify/check_gradle_version.rb"; do
  if [ ! -f "${verify_repo_root}/${required_file}" ]; then
    printf '%s\n' "error: required foundation file is missing: ${required_file}" >&2
    exit 1
  fi
done
printf '%s\n' "PASS foundation layout"

printf '%s\n' "Verifying declared host and Android toolchains..."
ruby "${verify_script_dir}/check_toolchains.rb"

printf '%s\n' "Verifying canonical schemas and transcripts..."
ruby "${verify_script_dir}/check_schema_data.rb"

verify_schema_probe="${verify_repo_root}/inkflow-schema-copy-probe.$$.schema.yaml"
if [ -e "${verify_schema_probe}" ]; then
  printf '%s\n' "error: schema-copy probe path already exists" >&2
  exit 1
fi
verify_cleanup_schema_probe() {
  case "${verify_schema_probe}" in
    "${verify_repo_root}"/inkflow-schema-copy-probe.*.schema.yaml)
      rm -f -- "${verify_schema_probe}"
      ;;
    *)
      printf '%s\n' \
        "warning: refusing to clean unexpected schema probe: ${verify_schema_probe}" >&2
      ;;
  esac
}
trap verify_cleanup_schema_probe EXIT HUP INT TERM
cp "${verify_repo_root}/schemas/source/inkflow.schema.yaml" \
  "${verify_schema_probe}"
if git -C "${verify_repo_root}" check-ignore --quiet -- "${verify_schema_probe}"; then
  printf '%s\n' "error: schema-copy probe is unexpectedly ignored" >&2
  exit 1
fi
if verify_schema_probe_output=$(ruby "${verify_script_dir}/check_schema_data.rb" 2>&1); then
  printf '%s\n' "error: schema verification accepted a non-ignored copy" >&2
  exit 1
fi
case "${verify_schema_probe_output}" in
  *"schema copies exist outside canonical/test roots"*"${verify_schema_probe}"*)
    ;;
  *)
    printf '%s\n' "error: schema-copy probe failed for an unexpected reason" >&2
    printf '%s\n' "${verify_schema_probe_output}" >&2
    exit 1
    ;;
esac
verify_cleanup_schema_probe
printf '%s\n' "PASS non-ignored schema copies remain rejected"

printf '%s\n' "Verifying exact dependency metadata..."
if [ "${verify_mode}" = "metadata-only" ]; then
  ruby "${verify_script_dir}/check_dependency_lock.rb" --metadata-only
else
  ruby "${verify_script_dir}/check_dependency_lock.rb"
fi

printf '%s\n' "Verifying CMake presets and foundation configuration..."
cmake -S "${verify_repo_root}" --list-presets=configure >/dev/null
cmake --preset foundation -S "${verify_repo_root}" >/dev/null
printf '%s\n' "PASS CMake foundation configuration"

verify_tmp_parent=${TMPDIR:-/tmp}
verify_tmp_dir=$(mktemp -d "${verify_tmp_parent%/}/inkflow-foundation.XXXXXX")
verify_cleanup() {
  case "${verify_tmp_dir}" in
    "${verify_tmp_parent%/}"/inkflow-foundation.*)
      rm -rf -- "${verify_tmp_dir}"
      ;;
    *)
      printf '%s\n' "warning: refusing to clean unexpected temporary path: ${verify_tmp_dir}" >&2
      ;;
  esac
}
trap verify_cleanup EXIT HUP INT TERM

printf '%s\n' "Verifying the non-product Apple project specification..."
mkdir -p "${verify_tmp_dir}/apple-a" "${verify_tmp_dir}/apple-b"
xcodegen \
  --quiet \
  --no-env \
  --spec "${verify_repo_root}/platforms/apple/project.yml" \
  --project-root "${verify_repo_root}/platforms/apple" \
  --project "${verify_tmp_dir}/apple-a" \
  --cache-path "${verify_tmp_dir}/xcodegen-cache-a"
xcodegen \
  --quiet \
  --no-env \
  --spec "${verify_repo_root}/platforms/apple/project.yml" \
  --project-root "${verify_repo_root}/platforms/apple" \
  --project "${verify_tmp_dir}/apple-b" \
  --cache-path "${verify_tmp_dir}/xcodegen-cache-b"
verify_apple_project_a="${verify_tmp_dir}/apple-a/InkFlow.xcodeproj/project.pbxproj"
verify_apple_project_b="${verify_tmp_dir}/apple-b/InkFlow.xcodeproj/project.pbxproj"
test -f "${verify_apple_project_a}"
test -f "${verify_apple_project_b}"
plutil -lint "${verify_apple_project_a}" >/dev/null
cmp "${verify_apple_project_a}" "${verify_apple_project_b}"
printf '%s\n' "PASS deterministic XcodeGen foundation project"

printf '%s\n' "Verifying Android toolchain declarations..."
ruby -rjson -e '
  root = ARGV.fetch(0)
  lock = JSON.parse(File.read(File.join(root, "toolchains.lock.json")))
  catalog = File.read(File.join(root, "platforms/android/gradle/libs.versions.toml"))
  expected = {
    "agp" => lock.dig("android", "androidGradlePluginVersion"),
    "compile-sdk" => lock.dig("android", "compileSdk").to_s,
    "target-sdk" => lock.dig("android", "targetSdk").to_s,
    "min-sdk" => lock.dig("android", "minSdk").to_s,
    "ndk" => lock.dig("android", "ndkVersion"),
    "cmake" => lock.dig("android", "cmakeVersion")
  }
  expected.each do |key, value|
    pattern = /^#{Regexp.escape(key)}\s*=\s*"#{Regexp.escape(value)}"$/
    abort "Android catalog mismatch for #{key}" unless catalog.match?(pattern)
  end
' "${verify_repo_root}"

verify_gradle_version=$(ruby -rjson -e '
  lock = JSON.parse(File.read(ARGV.fetch(0)))
  print lock.fetch("android").fetch("gradleVersion")
' "${verify_repo_root}/toolchains.lock.json")
verify_java_major=$(ruby -rjson -e '
  lock = JSON.parse(File.read(ARGV.fetch(0)))
  print lock.fetch("host").fetch("java").fetch("requiredMajorVersion")
' "${verify_repo_root}/toolchains.lock.json")
verify_gradle_checker="${verify_script_dir}/check_gradle_version.rb"

if printf '%s\n' 'Gradle 8.13' "Launcher JVM: ${verify_java_major}" | \
    ruby "${verify_gradle_checker}" "${verify_gradle_version}" \
      "${verify_java_major}" >/dev/null 2>&1; then
  printf '%s\n' "error: Gradle version gate accepted synthetic version 8.13" >&2
  exit 1
fi
printf '%s\n' "Gradle ${verify_gradle_version}" \
  "Launcher JVM: ${verify_java_major}" | \
  ruby "${verify_gradle_checker}" "${verify_gradle_version}" \
    "${verify_java_major}" >/dev/null
printf '%s\n' \
  "PASS Gradle/JVM gate rejects 8.13 and accepts ${verify_gradle_version}/Java ${verify_java_major}"

if [ -x "${verify_repo_root}/platforms/android/gradlew" ]; then
  verify_gradle_executable="${verify_repo_root}/platforms/android/gradlew"
  verify_gradle_label="wrapper"
elif command -v gradle >/dev/null 2>&1; then
  verify_gradle_executable=$(command -v gradle)
  verify_gradle_label="system Gradle"
else
  verify_gradle_executable=""
  verify_gradle_label=""
fi

if [ -n "${verify_gradle_executable}" ]; then
  verify_gradle_output=$("${verify_gradle_executable}" --version)
  printf '%s\n' "${verify_gradle_output}" | \
    ruby "${verify_gradle_checker}" "${verify_gradle_version}" \
      "${verify_java_major}"
  "${verify_gradle_executable}" \
    -p "${verify_repo_root}/platforms/android" \
    --offline --no-daemon --quiet projects >/dev/null
  printf '%s\n' "PASS Android Gradle project discovery (${verify_gradle_label}, offline)"
else
  printf '%s\n' "SKIP Android Gradle discovery (no wrapper or system Gradle yet)"
fi

printf '%s\n' "Verifying ignore boundaries..."
for ignored_path in \
    ".env" \
    "build/cmake/foundation/CMakeCache.txt" \
    "schemas/generated/inkflow.schema.yaml" \
    "platforms/apple/InkFlow.xcodeproj/project.pbxproj" \
    "platforms/android/local.properties" \
    "platforms/android/.gradle/state"; do
  if ! git -C "${verify_repo_root}" check-ignore --quiet -- "${ignored_path}"; then
    printf '%s\n' "error: expected ignored path is not ignored: ${ignored_path}" >&2
    exit 1
  fi
done

for canonical_path in \
    "schemas/source/inkflow.schema.yaml" \
    "schemas/source/inkflow.dict.yaml" \
    "schemas/test/inkflow_test.schema.yaml" \
    "testdata/transcripts/nihao.v1.json"; do
  if git -C "${verify_repo_root}" check-ignore --quiet -- "${canonical_path}"; then
    printf '%s\n' "error: canonical path is unexpectedly ignored: ${canonical_path}" >&2
    exit 1
  fi
done
printf '%s\n' "PASS generated/local ignore boundaries"

printf '%s\n' "Scanning repository inputs for obvious secrets and personal paths..."
verify_personal_path_regex="/""Users/[^/[:space:]]+/"
verify_private_key_regex="BEGIN ""(RSA |EC |OPENSSH )?PRIVATE KEY"
verify_token_regex="(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,})"
if rg \
    --hidden \
    --glob '!.git/**' \
    --glob '!build/**' \
    --glob '!third_party/**' \
    --line-number \
    "${verify_personal_path_regex}|${verify_private_key_regex}|${verify_token_regex}" \
    "${verify_repo_root}"; then
  printf '%s\n' "error: possible secret or machine-local path found" >&2
  exit 1
fi
printf '%s\n' "PASS secret and machine-local path scan"

printf '%s\n' "Foundation verification passed (${verify_mode})."
