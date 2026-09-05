#!/usr/bin/env ruby

require "minitest/autorun"
require "tempfile"
require_relative "../check_native_path_strings"

class CheckNativePathStringsTest < Minitest::Test
  def test_accepts_deterministic_virtual_paths
    with_binary("inkflow/source/engine.cc\0/android/ndk/sysroot\0libc.so") do |binary|
      assert InkFlow::NativePathStrings.verify(
        binary,
        forbidden_prefixes: ["/workspace/InkFlow"],
      )
    end
  end

  def test_rejects_common_machine_local_paths_without_printing_them
    [
      File.join("", "Users", "example", "InkFlow", "engine.cc"),
      "/home/example/InkFlow/engine.cc",
      "/private/var/folders/example/inkflow/build.o",
      "/var/folders/example/inkflow/build.o",
      "/Volumes/Workspace/InkFlow/engine.cc",
    ].each do |path|
      with_binary("prefix\0#{path}\0suffix") do |binary|
        error = assert_raises(InkFlow::NativePathStrings::Violation) do
          InkFlow::NativePathStrings.verify(binary)
        end
        refute_includes error.message, path
      end
    end
  end

  def test_allows_generic_runtime_paths_that_do_not_identify_the_build_host
    with_binary("/tmp/leveldbtest-%d\0/data/user/0/io.damao.inkflow") do |binary|
      assert InkFlow::NativePathStrings.verify(binary)
    end
  end

  def test_rejects_the_explicit_checkout_on_nonstandard_hosts
    checkout = "/opt/ci/build/InkFlow"
    with_binary("#{checkout}/third_party/source.cc") do |binary|
      assert_raises(InkFlow::NativePathStrings::Violation) do
        InkFlow::NativePathStrings.verify(binary, forbidden_prefixes: [checkout])
      end
    end
  end

  private

  def with_binary(contents)
    Tempfile.create("inkflow-native") do |file|
      file.binmode
      file.write(contents)
      file.flush
      yield file.path
    end
  end
end
