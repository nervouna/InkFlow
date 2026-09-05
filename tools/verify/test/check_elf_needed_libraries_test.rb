#!/usr/bin/env ruby

require "minitest/autorun"
require_relative "../check_elf_needed_libraries"

class CheckElfNeededLibrariesTest < Minitest::Test
  EXPECTED = %w[libc.so libdl.so libm.so].freeze

  def test_accepts_the_exact_needed_library_set
    assert checker.verify(report(*EXPECTED), expected: EXPECTED)
  end

  def test_rejects_dependencies_regardless_of_their_name_shape
    ["unexpected.so", "/system/lib64/unexpected.so"].each do |dependency|
      assert_raises(InkFlow::ElfNeededLibraries::Violation) do
        checker.verify(report(*EXPECTED, dependency), expected: EXPECTED)
      end
    end
  end

  def test_rejects_missing_and_duplicate_dependencies
    assert_raises(InkFlow::ElfNeededLibraries::Violation) do
      checker.verify(report("libc.so", "libdl.so"), expected: EXPECTED)
    end
    assert_raises(InkFlow::ElfNeededLibraries::Violation) do
      checker.verify(report(*EXPECTED, "libm.so"), expected: EXPECTED)
    end
  end

  def test_rejects_missing_unterminated_and_multiple_blocks
    [
      "File: lib.so\n",
      "NeededLibraries [\n  libc.so\n",
      "#{report(*EXPECTED)}#{report(*EXPECTED)}",
    ].each do |invalid_report|
      assert_raises(InkFlow::ElfNeededLibraries::Violation) do
        checker.verify(invalid_report, expected: EXPECTED)
      end
    end
  end

  private

  def checker
    InkFlow::ElfNeededLibraries
  end

  def report(*dependencies)
    <<~REPORT
      File: libinkflow_android.so
      NeededLibraries [
      #{dependencies.map { |dependency| "  #{dependency}" }.join("\n")}
      ]
    REPORT
  end
end
