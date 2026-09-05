#!/usr/bin/env ruby

expected_version = ARGV.fetch(0) do
  warn "usage: #{File.basename($PROGRAM_NAME)} EXPECTED_VERSION EXPECTED_JAVA_MAJOR"
  exit 2
end
expected_java_major = ARGV.fetch(1) do
  warn "usage: #{File.basename($PROGRAM_NAME)} EXPECTED_VERSION EXPECTED_JAVA_MAJOR"
  exit 2
end

unless ARGV.length == 2 && expected_version.match?(/\A\d+(?:\.\d+)+\z/) &&
    expected_java_major.match?(/\A\d+\z/)
  warn "usage: #{File.basename($PROGRAM_NAME)} EXPECTED_VERSION EXPECTED_JAVA_MAJOR"
  exit 2
end

output_lines = $stdin.read.lines
reported_versions = output_lines.map do |line|
  line.strip[/\AGradle\s+(\S+)\z/, 1]
end.compact
launcher_java_majors = output_lines.map do |line|
  line.strip[/\ALauncher JVM:\s+(\d+)(?:[.\s]|\z)/, 1]
end.compact

if reported_versions.length != 1
  warn "Gradle version verification failed: expected one 'Gradle VERSION' line"
  exit 1
end

actual_version = reported_versions.fetch(0)
unless actual_version == expected_version
  warn "Gradle version verification failed: #{actual_version} does not match #{expected_version}"
  exit 1
end

if launcher_java_majors.length != 1
  warn "Gradle JVM verification failed: expected one 'Launcher JVM: VERSION' line"
  exit 1
end

actual_java_major = launcher_java_majors.fetch(0)
unless actual_java_major == expected_java_major
  warn "Gradle JVM verification failed: #{actual_java_major} does not match #{expected_java_major}"
  exit 1
end

puts "PASS Gradle #{actual_version} and Launcher JVM #{actual_java_major} match toolchains.lock.json"
