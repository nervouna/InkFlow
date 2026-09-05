#!/usr/bin/env ruby

require "digest"
require "find"

module InkFlow
  module SourceTree
    class Violation < StandardError; end

    module_function

    def digest(root, exclude_git_metadata: false)
      expanded_root = File.expand_path(root)
      raise Violation, "source tree is missing: #{expanded_root}" unless File.directory?(expanded_root)

      prefix = "#{expanded_root}/"
      entries = []
      Find.find(expanded_root) do |path|
        next if path == expanded_root
        if exclude_git_metadata && File.basename(path) == ".git"
          Find.prune if File.directory?(path) && !File.symlink?(path)
          next
        end
        relative_path = path.delete_prefix(prefix).b
        entries << [relative_path, path]
      end

      result = Digest::SHA256.new
      digest_domain = if exclude_git_metadata
                        "InkFlow source tree v2 without Git metadata\0"
                      else
                        "InkFlow source tree v1\0"
                      end
      result.update(digest_domain)
      entries.sort_by(&:first).each do |relative_path, path|
        stat = File.lstat(path)
        if stat.directory?
          result.update("D")
          update_field(result, relative_path)
        elsif stat.file?
          result.update("F")
          update_field(result, relative_path)
          result.update([stat.size].pack("Q>"))
          File.open(path, "rb") do |file|
            while (chunk = file.read(1024 * 1024))
              result.update(chunk)
            end
          end
        elsif stat.symlink?
          result.update("L")
          update_field(result, relative_path)
          update_field(result, File.readlink(path).b)
        else
          raise Violation, "unsupported source-tree entry: #{relative_path}"
        end
      end
      result.hexdigest
    rescue SystemCallError => error
      raise Violation, "could not inspect source tree: #{error.message}"
    end

    def verify(root, expected:, exclude_git_metadata: false)
      unless expected.match?(/\A[0-9a-f]{64}\z/)
        raise Violation, "expected source-tree digest is not SHA-256"
      end

      actual = digest(root, exclude_git_metadata: exclude_git_metadata)
      unless actual == expected
        raise Violation, "source tree digest #{actual} does not match #{expected}"
      end
      true
    end

    def update_field(result, value)
      bytes = value.b
      result.update([bytes.bytesize].pack("Q>"))
      result.update(bytes)
    end
    private_class_method :update_field
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: #{File.basename($PROGRAM_NAME)} SOURCE_TREE EXPECTED_SHA256" unless ARGV.length == 2

  begin
    InkFlow::SourceTree.verify(ARGV[0], expected: ARGV[1])
    puts "PASS source tree matches the locked digest"
  rescue InkFlow::SourceTree::Violation => error
    warn "source-tree verification failed: #{error.message}"
    exit 1
  end
end
