#!/usr/bin/env ruby

module InkFlow
  module NativePathStrings
    MACHINE_LOCAL_PREFIXES = [
      "/Users/",
      "/home/",
      "/private/var/folders/",
      "/var/folders/",
      "/Volumes/",
    ].freeze

    class Violation < StandardError; end

    module_function

    def verify(binary, forbidden_prefixes: [])
      contents = File.binread(binary)
      prefixes = (MACHINE_LOCAL_PREFIXES + forbidden_prefixes).uniq
      matches = prefixes.select { |prefix| contents.include?(prefix.b) }
      return true if matches.empty?

      raise Violation,
            "native binary contains #{matches.length} forbidden machine-local path prefix(es)"
    rescue Errno::ENOENT, Errno::EACCES => error
      raise Violation, "native binary could not be read: #{error.message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  binary = ARGV.shift
  if binary.nil? || ARGV.any? { |prefix| prefix.empty? || !prefix.start_with?("/") }
    warn "usage: #{File.basename($PROGRAM_NAME)} BINARY [ABSOLUTE_PREFIX ...]"
    exit 2
  end

  begin
    InkFlow::NativePathStrings.verify(binary, forbidden_prefixes: ARGV)
  rescue InkFlow::NativePathStrings::Violation => error
    warn "native path verification failed: #{error.message}"
    exit 1
  end

  puts "PASS packaged native library contains no machine-local absolute paths"
end
