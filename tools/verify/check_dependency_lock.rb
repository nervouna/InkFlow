#!/usr/bin/env ruby

require "json"
require "open3"

repo_root = File.expand_path("../..", __dir__)
metadata_only = ARGV == ["--metadata-only"]

unless ARGV.empty? || metadata_only
  warn "usage: #{File.basename($PROGRAM_NAME)} [--metadata-only]"
  exit 2
end

def fail_check(message)
  warn "dependency verification failed: #{message}"
  exit 1
end

def capture(*command)
  output, status = Open3.capture2e(*command)
  fail_check("command failed: #{command.join(' ')}\n#{output}") unless status.success?
  output.strip
end

lock_path = File.join(repo_root, "dependencies.lock.json")
lock = JSON.parse(File.read(lock_path, encoding: "UTF-8"))
fail_check("unsupported lock format") unless lock["formatVersion"] == 1

librime = lock.dig("dependencies", "librime")
fail_check("librime lock record is missing") unless librime.is_a?(Hash)

required_fields = %w[repository path version tagRef tagObject commit submodules license]
missing_fields = required_fields.reject { |field| librime[field].is_a?(String) && !librime[field].empty? }
fail_check("librime lock fields missing: #{missing_fields.join(', ')}") unless missing_fields.empty?
fail_check("librime must use recursive submodules") unless librime["submodules"] == "recursive"
fail_check("librime commit must be a full SHA-1") unless librime["commit"].match?(/\A[0-9a-f]{40}\z/)
fail_check("librime tag object must be a full SHA-1") unless librime["tagObject"].match?(/\A[0-9a-f]{40}\z/)

gitmodules_path = File.join(repo_root, ".gitmodules")
if !File.file?(gitmodules_path)
  if metadata_only
    puts "SKIP real librime submodule (metadata-only authoring check)"
    puts "PASS dependency lock metadata"
    exit 0
  end
  fail_check(".gitmodules is missing")
end

submodule_name = librime["path"]
configured_path = capture("git", "-C", repo_root, "config", "-f", gitmodules_path,
                          "--get", "submodule.#{submodule_name}.path")
configured_url = capture("git", "-C", repo_root, "config", "-f", gitmodules_path,
                         "--get", "submodule.#{submodule_name}.url")
fail_check("submodule path does not match lock") unless configured_path == librime["path"]
fail_check("submodule URL does not match lock") unless configured_url == librime["repository"]

indexed_entry = capture("git", "-C", repo_root, "ls-files", "--stage", "--", librime["path"])
if indexed_entry.empty?
  fail_check("librime gitlink is not recorded in the parent index") unless metadata_only
else
  indexed_mode, indexed_commit, = indexed_entry.split
  fail_check("librime index entry is not a gitlink") unless indexed_mode == "160000"
  unless indexed_commit == librime["commit"]
    fail_check("librime gitlink #{indexed_commit} does not match #{librime['commit']}")
  end
end

checkout_path = File.join(repo_root, librime["path"])
if !File.directory?(File.join(checkout_path, ".git")) && !File.file?(File.join(checkout_path, ".git"))
  if metadata_only
    puts "SKIP checked-out librime commit (metadata-only authoring check)"
    puts "PASS dependency lock and submodule declaration"
    exit 0
  end
  fail_check("librime checkout is not initialized; run tools/bootstrap/bootstrap.sh")
end

actual_commit = capture("git", "-C", checkout_path, "rev-parse", "HEAD")
fail_check("librime checkout #{actual_commit} does not match #{librime['commit']}") unless actual_commit == librime["commit"]

origin_url = capture("git", "-C", checkout_path, "remote", "get-url", "origin")
fail_check("librime origin URL does not match lock") unless origin_url == librime["repository"]

recursive_status = capture("git", "-C", repo_root, "submodule", "status", "--recursive")
bad_status = recursive_status.lines.find do |line|
  status = line[0]
  ["-", "+", "U"].include?(status)
end
fail_check("recursive submodule is missing or at the wrong commit: #{bad_status}") if bad_status

recursive_paths = recursive_status.lines.map { |line| line.split[1] }.compact
recursive_paths.each do |path|
  checkout = File.join(repo_root, path)
  dirty_status = capture(
    "git", "-C", checkout, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=none"
  )
  fail_check("submodule has tracked modifications: #{path}\n#{dirty_status}") unless dirty_status.empty?
end

librime_license_path = File.join(checkout_path, "LICENSE")
fail_check("librime license file is missing") unless File.file?(librime_license_path)

puts "PASS dependency lock, submodule declaration, and recursive checkout"
