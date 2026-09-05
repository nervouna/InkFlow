#!/usr/bin/env ruby

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../check_git_worktree"

class CheckGitWorktreeTest < Minitest::Test
  def test_requires_git_top_level_inspection
    assert_equal ["rev-parse", "--show-toplevel"],
                 InkFlow::GitWorktree::TOP_LEVEL_ARGUMENTS
  end

  def test_accepts_the_same_real_worktree_path
    Dir.mktmpdir("inkflow-worktree-binding") do |root|
      checkout = File.join(root, "checkout")
      FileUtils.mkdir_p(checkout)

      assert InkFlow::GitWorktree.verify_checkout_binding(
        File.join(checkout, "."),
        checkout,
      )
    end
  end

  def test_rejects_a_redirected_worktree_path
    Dir.mktmpdir("inkflow-worktree-binding") do |root|
      checkout = File.join(root, "checkout")
      redirected = File.join(root, "redirected")
      FileUtils.mkdir_p([checkout, redirected])

      error = assert_raises(InkFlow::GitWorktree::Violation) do
        InkFlow::GitWorktree.verify_checkout_binding(checkout, redirected)
      end
      assert_includes error.message, "unexpected Git worktree"
    end
  end

  def test_status_command_requests_untracked_and_ignored_files
    assert_includes InkFlow::GitWorktree::STATUS_ARGUMENTS, "--untracked-files=all"
    refute_includes InkFlow::GitWorktree::STATUS_ARGUMENTS, "--untracked-files=no"
    assert_includes InkFlow::GitWorktree::STATUS_ARGUMENTS, "--ignored=matching"
  end

  def test_rejects_tracked_untracked_and_ignored_status_rows
    [
      " M tracked.cc\n",
      "?? untracked.cc\n",
      "!! plugins/ignored/\n",
    ].each do |status_output|
      error = assert_raises(InkFlow::GitWorktree::Violation) do
        InkFlow::GitWorktree.verify_status_output(status_output)
      end
      assert_includes error.message, status_output.strip
    end
  end

  def test_accepts_an_empty_status
    assert InkFlow::GitWorktree.verify_status_output("")
  end

  def test_rejects_assume_unchanged_and_skip_worktree_index_entries
    ["h source.cc\n", "S source.cc\n"].each do |index_output|
      error = assert_raises(InkFlow::GitWorktree::Violation) do
        InkFlow::GitWorktree.verify_index_output(index_output)
      end
      assert_includes error.message, index_output.strip
    end
  end

  def test_accepts_only_normal_cached_index_entries
    assert InkFlow::GitWorktree.verify_index_output("H source.cc\nH deps/library\n")
  end
end
