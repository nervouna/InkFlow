#!/usr/bin/env ruby

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../check_source_tree"

class CheckSourceTreeTest < Minitest::Test
  EXPECTED_FIXTURE_DIGEST =
    "22cd6788eaa02cc55c18ffbf8efb04fc3d61fd70aea885836089961ec1ae6f59".freeze

  def setup
    @temporary_directory = Dir.mktmpdir("inkflow-source-tree-test")
    FileUtils.mkdir_p(File.join(@temporary_directory, "include", "nested"))
    File.binwrite(File.join(@temporary_directory, "README"), "root\n")
    File.binwrite(
      File.join(@temporary_directory, "include", "nested", "header.hpp"),
      "#define VALUE 1\n",
    )
    File.symlink("nested/header.hpp", File.join(@temporary_directory, "include", "current.hpp"))
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory
  end

  def test_digest_is_stable_and_verifiable
    assert_equal EXPECTED_FIXTURE_DIGEST, source_tree.digest(@temporary_directory)
    assert source_tree.verify(@temporary_directory, expected: EXPECTED_FIXTURE_DIGEST)
  end

  def test_rejects_modified_added_and_deleted_files
    assert_mutation_rejected do
      File.binwrite(File.join(@temporary_directory, "README"), "changed\n")
    end
    assert_mutation_rejected do
      File.binwrite(File.join(@temporary_directory, "extra"), "unexpected\n")
    end
    assert_mutation_rejected do
      FileUtils.rm(File.join(@temporary_directory, "README"))
    end
  end

  def test_rejects_changed_entry_kind_and_symlink_target
    assert_mutation_rejected do
      link = File.join(@temporary_directory, "include", "current.hpp")
      FileUtils.rm(link)
      File.binwrite(link, "nested/header.hpp")
    end
    assert_mutation_rejected do
      link = File.join(@temporary_directory, "include", "current.hpp")
      FileUtils.rm(link)
      File.symlink("../README", link)
    end
  end

  def test_git_metadata_can_be_excluded_without_hiding_source_changes
    git_entry = File.join(@temporary_directory, ".git")
    File.binwrite(git_entry, "gitdir: ../first\n")
    expected = source_tree.digest(
      @temporary_directory,
      exclude_git_metadata: true,
    )

    File.binwrite(git_entry, "gitdir: ../second\n")
    assert source_tree.verify(
      @temporary_directory,
      expected: expected,
      exclude_git_metadata: true,
    )

    FileUtils.rm(git_entry)
    FileUtils.mkdir_p(File.join(git_entry, "objects"))
    File.binwrite(File.join(git_entry, "config"), "[core]\n")
    assert source_tree.verify(
      @temporary_directory,
      expected: expected,
      exclude_git_metadata: true,
    )

    File.binwrite(File.join(@temporary_directory, "unexpected.cc"), "changed\n")
    assert_raises(InkFlow::SourceTree::Violation) do
      source_tree.verify(
        @temporary_directory,
        expected: expected,
        exclude_git_metadata: true,
      )
    end
  end

  private

  def source_tree
    InkFlow::SourceTree
  end

  def assert_mutation_rejected
    pristine_copy = Dir.mktmpdir("inkflow-source-tree-copy")
    FileUtils.copy_entry(@temporary_directory, pristine_copy)
    yield
    assert_raises(InkFlow::SourceTree::Violation) do
      source_tree.verify(@temporary_directory, expected: EXPECTED_FIXTURE_DIGEST)
    end
  ensure
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory
    @temporary_directory = pristine_copy
  end
end
