#!/usr/bin/env ruby

require "minitest/autorun"
require "open3"

class CheckGradleVersionTest < Minitest::Test
  CHECKER = File.expand_path("../check_gradle_version.rb", __dir__)

  def test_accepts_the_locked_gradle_and_launcher_jvm
    output = <<~OUTPUT
      ------------------------------------------------------------
      Gradle 9.3.1
      ------------------------------------------------------------
      Launcher JVM: 17.0.20.1 (Homebrew 17.0.20.1+0)
    OUTPUT

    _stdout, stderr, status = Open3.capture3(
      "ruby", CHECKER, "9.3.1", "17", stdin_data: output
    )

    assert_predicate status, :success?, stderr
  end

  def test_rejects_a_different_launcher_jvm_even_when_path_java_is_correct
    output = "Gradle 9.3.1\nLauncher JVM: 21.0.6 (fake)\n"

    _stdout, _stderr, status = Open3.capture3(
      "ruby", CHECKER, "9.3.1", "17", stdin_data: output
    )

    refute_predicate status, :success?
  end

  def test_rejects_missing_launcher_jvm_evidence
    _stdout, _stderr, status = Open3.capture3(
      "ruby", CHECKER, "9.3.1", "17", stdin_data: "Gradle 9.3.1\n"
    )

    refute_predicate status, :success?
  end
end
