#!/usr/bin/env ruby

expected_version = ARGV.fetch(0) do
  warn "usage: #{File.basename($PROGRAM_NAME)} EXPECTED_VERSION"
  exit 2
end

unless ARGV.length == 1 && expected_version.match?(/\A\d+(?:\.\d+)+\z/)
  warn "usage: #{File.basename($PROGRAM_NAME)} EXPECTED_VERSION"
  exit 2
end

reported_versions = $stdin.read.lines.filter_map do |line|
  line.strip[/\AGradle\s+(\S+)\z/, 1]
end

if reported_versions.length != 1
  warn "Gradle version verification failed: expected one 'Gradle VERSION' line"
  exit 1
end

actual_version = reported_versions.fetch(0)
unless actual_version == expected_version
  warn "Gradle version verification failed: #{actual_version} does not match #{expected_version}"
  exit 1
end

puts "PASS Gradle #{actual_version} matches toolchains.lock.json"
