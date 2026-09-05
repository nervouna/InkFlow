#!/usr/bin/env ruby

module InkFlow
  module ElfNeededLibraries
    class Violation < StandardError; end

    module_function

    def verify(readobj_output, expected:)
      starts = readobj_output.lines.each_index.select do |index|
        readobj_output.lines[index].strip == "NeededLibraries ["
      end
      unless starts.length == 1
        raise Violation, "expected exactly one NeededLibraries block"
      end

      lines = readobj_output.lines
      start = starts.fetch(0)
      finish = ((start + 1)...lines.length).find { |index| lines[index].strip == "]" }
      raise Violation, "unterminated NeededLibraries block" unless finish

      actual = lines[(start + 1)...finish].map(&:strip).reject(&:empty?)
      unless actual.sort == expected.sort
        raise Violation, "ELF dependencies do not exactly match the expected set"
      end
      true
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.empty? || ARGV.any?(&:empty?)
    warn "usage: #{File.basename($PROGRAM_NAME)} EXPECTED_LIBRARY [...]"
    exit 2
  end

  begin
    InkFlow::ElfNeededLibraries.verify($stdin.read, expected: ARGV)
  rescue InkFlow::ElfNeededLibraries::Violation => error
    warn "ELF dependency verification failed: #{error.message}"
    exit 1
  end

  puts "PASS packaged native library has the exact expected ELF dependencies"
end
