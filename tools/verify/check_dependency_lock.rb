#!/usr/bin/env ruby

require "json"
require "open3"
require_relative "check_git_worktree"
require_relative "check_source_tree"

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
boost = lock.dig("dependencies", "boost")
fail_check("Boost lock record is missing") unless boost.is_a?(Hash)

required_fields = %w[
  repository
  path
  version
  tagRef
  tagObject
  commit
  sourceTreeSha256
  submodules
  license
]
missing_fields = required_fields.reject { |field| librime[field].is_a?(String) && !librime[field].empty? }
fail_check("librime lock fields missing: #{missing_fields.join(', ')}") unless missing_fields.empty?
fail_check("librime must use recursive submodules") unless librime["submodules"] == "recursive"
fail_check("librime commit must be a full SHA-1") unless librime["commit"].match?(/\A[0-9a-f]{40}\z/)
fail_check("librime tag object must be a full SHA-1") unless librime["tagObject"].match?(/\A[0-9a-f]{40}\z/)
unless librime["sourceTreeSha256"].match?(/\A[0-9a-f]{64}\z/)
  fail_check("librime source-tree digest must be SHA-256")
end

boost_required_fields = %w[
  role
  source
  version
  sha256
  sourceTreeSha256
  provenance
  license
]
boost_missing_fields = boost_required_fields.reject do |field|
  boost[field].is_a?(String) && !boost[field].empty?
end
fail_check("Boost lock fields missing: #{boost_missing_fields.join(', ')}") unless boost_missing_fields.empty?
fail_check("Boost digest must be SHA-256") unless boost["sha256"].match?(/\A[0-9a-f]{64}\z/)
unless boost["sourceTreeSha256"].match?(/\A[0-9a-f]{64}\z/)
  fail_check("Boost source-tree digest must be SHA-256")
end

librime_boost_script_path =
  File.join(repo_root, "third_party/librime/install-boost.sh")
if File.file?(librime_boost_script_path)
  librime_boost_script = File.read(librime_boost_script_path, encoding: "UTF-8")
  unless librime_boost_script.include?("boost_version=\"${boost_version=#{boost['version']}}\"") &&
         librime_boost_script.include?("#{boost['sha256']}  ${boost_tarball}")
    fail_check("Boost lock does not match librime's pinned install script")
  end
elsif !metadata_only
  fail_check("librime Boost install script is missing")
end

engine_cmake = File.read(File.join(repo_root, "engine/CMakeLists.txt"), encoding: "UTF-8")
unless engine_cmake.include?(boost["source"]) && engine_cmake.include?(boost["sha256"])
  fail_check("engine CMake Boost source or digest does not match dependency lock")
end

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
  begin
    InkFlow::GitWorktree.verify_clean(checkout)
  rescue InkFlow::GitWorktree::Violation => error
    fail_check("submodule is not clean: #{path}\n#{error.message}")
  end
end

begin
  InkFlow::SourceTree.verify(
    checkout_path,
    expected: librime.fetch("sourceTreeSha256"),
    exclude_git_metadata: true,
  )
rescue InkFlow::SourceTree::Violation => error
  fail_check("librime source tree is not pristine: #{error.message}")
end

boost_cache_key = "boost-#{boost.fetch('version')}-#{boost.fetch('sha256')}"
boost_cache_root = File.join(repo_root, "build/dependencies")
boost_source_path = File.join(boost_cache_root, "sources", boost_cache_key)
boost_ready_path = File.join(boost_cache_root, "ready", "#{boost_cache_key}.sha256")
boost_source_exists = File.directory?(boost_source_path)
boost_ready_exists = File.file?(boost_ready_path)
if boost_source_exists != boost_ready_exists
  fail_check("Boost source cache and ready marker must either both exist or both be absent")
elsif boost_source_exists
  ready_digest = File.read(boost_ready_path, encoding: "UTF-8").strip
  fail_check("Boost ready marker does not match the archive lock") unless ready_digest == boost["sha256"]
  begin
    InkFlow::SourceTree.verify(
      boost_source_path,
      expected: boost.fetch("sourceTreeSha256"),
    )
  rescue InkFlow::SourceTree::Violation => error
    fail_check("Boost source cache is not pristine: #{error.message}")
  end
else
  puts "SKIP absent Boost source cache (the pinned URL_HASH must populate it before use)"
end

librime_license_path = File.join(checkout_path, "LICENSE")
fail_check("librime license file is missing") unless File.file?(librime_license_path)

if boost_source_exists
  puts "PASS dependency lock, recursive checkout, librime tree, and Boost tree digests"
else
  puts "PASS dependency lock, recursive checkout, and librime source-tree digest"
end
