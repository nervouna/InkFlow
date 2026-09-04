#!/usr/bin/env ruby

require "json"
require "open3"
require "yaml"

repo_root = File.expand_path("../..", __dir__)
lock = JSON.parse(File.read(File.join(repo_root, "toolchains.lock.json"), encoding: "UTF-8"))

def fail_check(message)
  warn "toolchain verification failed: #{message}"
  exit 1
end

def capture(*command)
  output, status = Open3.capture2e(*command)
  fail_check("command failed: #{command.join(' ')}\n#{output}") unless status.success?
  output
end

def version_parts(version)
  version.scan(/\d+/).map(&:to_i)
end

def version_at_least?(actual, minimum)
  width = [version_parts(actual).length, version_parts(minimum).length].max
  actual_parts = version_parts(actual).fill(0, version_parts(actual).length...width)
  minimum_parts = version_parts(minimum).fill(0, version_parts(minimum).length...width)
  (actual_parts <=> minimum_parts) >= 0
end

host = lock.fetch("host")

cmake_presets = JSON.parse(File.read(File.join(repo_root, "CMakePresets.json"), encoding: "UTF-8"))
preset_minimum_parts = cmake_presets.fetch("cmakeMinimumRequired").values_at("major", "minor", "patch")
preset_minimum = preset_minimum_parts.join(".")
locked_cmake_minimum = host.dig("cmake", "minimumVersion")
fail_check("CMake preset minimum #{preset_minimum} does not match lock #{locked_cmake_minimum}") unless preset_minimum == locked_cmake_minimum

apple_project = YAML.safe_load(
  File.read(File.join(repo_root, "platforms", "apple", "project.yml"), encoding: "UTF-8"),
  aliases: true
)
project_xcodegen_minimum = apple_project.dig("options", "minimumXcodeGenVersion")
locked_xcodegen_version = host.dig("xcodegen", "requiredVersion")
fail_check("Apple XcodeGen minimum does not match the exact lock") unless project_xcodegen_minimum == locked_xcodegen_version

cmake_version = capture("cmake", "--version")[/cmake version (\S+)/, 1]
fail_check("could not read CMake version") unless cmake_version
cmake_minimum = locked_cmake_minimum
fail_check("CMake #{cmake_version} is older than #{cmake_minimum}") unless version_at_least?(cmake_version, cmake_minimum)

xcodegen_version = capture("xcodegen", "--version")[/Version:\s*(\S+)/, 1]
xcodegen_required = locked_xcodegen_version
fail_check("could not read XcodeGen version") unless xcodegen_version
fail_check("XcodeGen #{xcodegen_version} does not match #{xcodegen_required}") unless xcodegen_version == xcodegen_required

ruby_minimum = host.dig("ruby", "minimumVersion")
fail_check("Ruby #{RUBY_VERSION} is older than #{ruby_minimum}") unless version_at_least?(RUBY_VERSION, ruby_minimum)

java_version_output = capture("java", "-version")
java_version = java_version_output[/version "([^"]+)"/, 1]
java_required_major = host.dig("java", "requiredMajorVersion")
fail_check("could not read Java version") unless java_version
fail_check("Java #{java_version} does not have required major #{java_required_major}") unless version_parts(java_version).first == java_required_major

android = lock.fetch("android")
android_home = ENV["ANDROID_HOME"] || ENV["ANDROID_SDK_ROOT"]
if android_home
  required_android_paths = [
    File.join(android_home, "platforms", "android-#{android.fetch('compileSdk')}"),
    File.join(android_home, "ndk", android.fetch("ndkVersion")),
    File.join(android_home, "cmake", android.fetch("cmakeVersion"))
  ]
  missing_android_paths = required_android_paths.reject { |path| File.directory?(path) }
  fail_check("Android SDK components are missing: #{missing_android_paths.join(', ')}") unless missing_android_paths.empty?
  puts "PASS Android SDK platform, NDK, and CMake declarations"
else
  puts "SKIP installed Android SDK components (ANDROID_HOME/ANDROID_SDK_ROOT is unset)"
end

puts "PASS host CMake, XcodeGen, Ruby, and Java requirements"
