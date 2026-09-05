#!/usr/bin/env ruby

require "open3"

module InkFlow
  module GitWorktree
    TOP_LEVEL_ARGUMENTS = ["rev-parse", "--show-toplevel"].freeze
    STATUS_ARGUMENTS = [
      "status",
      "--porcelain=v1",
      "--untracked-files=all",
      "--ignored=matching",
      "--ignore-submodules=none",
    ].freeze
    INDEX_ARGUMENTS = ["ls-files", "-v"].freeze

    class Violation < StandardError; end

    module_function

    def verify_clean(checkout)
      top_level_output, top_level_status = Open3.capture2e(
        "git", "-C", checkout, *TOP_LEVEL_ARGUMENTS
      )
      unless top_level_status.success?
        raise Violation,
              "git top-level inspection failed for #{checkout}: #{top_level_output.strip}"
      end
      verify_checkout_binding(checkout, top_level_output.strip)

      output, status = Open3.capture2e("git", "-C", checkout, *STATUS_ARGUMENTS)
      unless status.success?
        raise Violation, "git status failed for #{checkout}: #{output.strip}"
      end

      verify_status_output(output)

      index_output, index_status = Open3.capture2e("git", "-C", checkout, *INDEX_ARGUMENTS)
      unless index_status.success?
        raise Violation, "git index inspection failed for #{checkout}: #{index_output.strip}"
      end

      verify_index_output(index_output)
    end

    def verify_checkout_binding(checkout, reported_top_level)
      expected = File.realpath(checkout)
      actual = File.realpath(reported_top_level)
      return true if actual == expected

      raise Violation,
            "checkout resolves to unexpected Git worktree: expected #{expected}, got #{actual}"
    rescue SystemCallError => error
      raise Violation, "could not resolve Git worktree binding: #{error.message}"
    end

    def verify_status_output(output)
      changes = output.strip
      unless changes.empty?
        raise Violation, "checkout contains tracked, untracked, or ignored changes:\n#{changes}"
      end
      true
    end

    def verify_index_output(output)
      non_normal = output.each_line.map(&:chomp).reject(&:empty?).reject do |entry|
        entry.start_with?("H ")
      end
      unless non_normal.empty?
        raise Violation,
          "checkout index contains non-normal tracked entries:\n#{non_normal.join("\n")}"
      end
      true
    end
  end
end
