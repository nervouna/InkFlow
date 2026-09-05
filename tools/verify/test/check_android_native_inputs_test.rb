#!/usr/bin/env ruby

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../check_android_native_inputs"

class CheckAndroidNativeInputsTest < Minitest::Test
  REPO_ROOT = "/workspace/InkFlow"
  DEPENDENCY_CACHE = "#{REPO_ROOT}/build/dependencies"
  BOOST_SOURCE = "#{DEPENDENCY_CACHE}/sources/boost-locked"
  SDK_ROOT = "/opt/android-sdk"
  NDK_VERSION = "28.2.13676358"
  CMAKE_VERSION = "3.22.1"
  MIN_SDK = "26"
  NDK_ROOT = "#{SDK_ROOT}/ndk/#{NDK_VERSION}"
  CMAKE_ROOT = "#{SDK_ROOT}/cmake/#{CMAKE_VERSION}"
  PYTHON_EXECUTABLE = "#{REPO_ROOT}/tools/build/python-isolated"
  TOOLCHAIN_BIN = "#{NDK_ROOT}/toolchains/llvm/prebuilt/darwin-x86_64/bin"
  BUILD_HASH = "lockedhash"
  BUILD_DIRECTORY = "#{REPO_ROOT}/platforms/android/app/.cxx/RelWithDebInfo/#{BUILD_HASH}/arm64-v8a"
  OUTPUT_DIRECTORY = "#{REPO_ROOT}/platforms/android/app/build/intermediates/cxx/RelWithDebInfo/#{BUILD_HASH}/obj/arm64-v8a"
  LOCKED_EMPTY_CMAKE_FLAGS = %w[
    CMAKE_C_FLAGS
    CMAKE_CXX_FLAGS
    CMAKE_EXE_LINKER_FLAGS
    CMAKE_MODULE_LINKER_FLAGS
    CMAKE_SHARED_LINKER_FLAGS
    CMAKE_STATIC_LINKER_FLAGS
  ].freeze
  LOCKED_EMPTY_CMAKE_LAUNCHERS = %w[
    CMAKE_C_COMPILER_LAUNCHER
    CMAKE_CXX_COMPILER_LAUNCHER
    CMAKE_C_LINKER_LAUNCHER
    CMAKE_CXX_LINKER_LAUNCHER
  ].freeze
  LOCKED_EMPTY_CMAKE_PATHS = %w[
    CMAKE_MODULE_PATH
    CMAKE_PREFIX_PATH
    CMAKE_PROJECT_INCLUDE
    CMAKE_PROJECT_INCLUDE_BEFORE
    CMAKE_PROJECT_InkFlow_INCLUDE
    CMAKE_PROJECT_InkFlow_INCLUDE_BEFORE
    CMAKE_PROJECT_TOP_LEVEL_INCLUDES
    CMAKE_USER_MAKE_RULES_OVERRIDE
    CMAKE_USER_MAKE_RULES_OVERRIDE_C
    CMAKE_USER_MAKE_RULES_OVERRIDE_CXX
  ].freeze
  LOCKED_EMPTY_CMAKE_INPUTS = (
    LOCKED_EMPTY_CMAKE_FLAGS + LOCKED_EMPTY_CMAKE_LAUNCHERS +
      LOCKED_EMPTY_CMAKE_PATHS
  ).freeze

  CXX_MODEL = JSON.generate(
    "configurationArguments" => [
      "-H#{REPO_ROOT}",
      "-DCMAKE_SYSTEM_NAME=Android",
      "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
      "-DCMAKE_SYSTEM_VERSION=#{MIN_SDK}",
      "-DANDROID_PLATFORM=android-#{MIN_SDK}",
      "-DANDROID_ABI=arm64-v8a",
      "-DCMAKE_ANDROID_ARCH_ABI=arm64-v8a",
      "-DANDROID_NDK=#{NDK_ROOT}",
      "-DCMAKE_ANDROID_NDK=#{NDK_ROOT}",
      "-DCMAKE_TOOLCHAIN_FILE=#{NDK_ROOT}/build/cmake/android.toolchain.cmake",
      "-DCMAKE_MAKE_PROGRAM=#{CMAKE_ROOT}/bin/ninja",
      "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=#{OUTPUT_DIRECTORY}",
      "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=#{OUTPUT_DIRECTORY}",
      "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
      "-B#{BUILD_DIRECTORY}",
      "-GNinja",
      "-DANDROID_STL=c++_static",
      "-DBUILD_TESTING=OFF",
      "-DINKFLOW_BUILD_APPLE_PACKAGING_TOOLS=OFF",
      "-DINKFLOW_DEPENDENCY_CACHE_DIR=#{DEPENDENCY_CACHE}",
      "-DPYTHON_EXECUTABLE=#{PYTHON_EXECUTABLE}",
    ],
    "buildSettings" => {"environmentVariables" => []},
    "cmake" => {
      "effectiveConfiguration" => {
        "inheritEnvironments" => [],
        "variables" => [],
      },
    },
    "variant" => {
      "buildSystemArgumentList" => [
        "-DANDROID_STL=c++_static",
        "-DBUILD_TESTING=OFF",
        "-DINKFLOW_BUILD_APPLE_PACKAGING_TOOLS=OFF",
        "-DINKFLOW_DEPENDENCY_CACHE_DIR=#{DEPENDENCY_CACHE}",
        "-DPYTHON_EXECUTABLE=#{PYTHON_EXECUTABLE}",
      ] + LOCKED_EMPTY_CMAKE_INPUTS.map { |name| "-D#{name}=" },
      "cFlagsList" => [],
      "cppFlagsList" => [],
      "module" => {
        "cmake" => {
          "cmakeExe" => "#{CMAKE_ROOT}/bin/cmake",
          "cmakeVersionFromDsl" => CMAKE_VERSION,
        },
        "cmakeToolchainFile" => "#{NDK_ROOT}/build/cmake/android.toolchain.cmake",
        "makeFile" => "#{REPO_ROOT}/CMakeLists.txt",
        "moduleRootFolder" => "#{REPO_ROOT}/platforms/android/app",
        "ndkFolder" => NDK_ROOT,
        "ndkFolderBeforeSymLinking" => NDK_ROOT,
        "ninjaExe" => "#{CMAKE_ROOT}/bin/ninja",
      },
    },
  )
  CMAKE_CACHE = (
    [
      "INKFLOW_DEPENDENCY_CACHE_DIR:PATH=#{DEPENDENCY_CACHE}",
      "PYTHON_EXECUTABLE:FILEPATH=#{PYTHON_EXECUTABLE}",
      "CMAKE_MAKE_PROGRAM:UNINITIALIZED=#{CMAKE_ROOT}/bin/ninja",
      "CMAKE_TOOLCHAIN_FILE:FILEPATH=#{NDK_ROOT}/build/cmake/android.toolchain.cmake",
    ] + LOCKED_EMPTY_CMAKE_FLAGS.map { |name| "#{name}:STRING=" }
  ).join("\n") + "\n"
  COMPILE_COMMANDS = JSON.generate(
    [
      {
        "directory" => BUILD_DIRECTORY,
        "file" => "#{REPO_ROOT}/engine/src/engine.cpp",
        "arguments" => ["#{TOOLCHAIN_BIN}/clang++", "-isystem", BOOST_SOURCE, "-c", "engine.cpp"],
      },
      {
        "directory" => BUILD_DIRECTORY,
        "file" => "#{REPO_ROOT}/third_party/librime/src/rime_api.cc",
        "command" => "#{TOOLCHAIN_BIN}/clang++ -isystem #{BOOST_SOURCE} -c rime_api.cc",
      },
    ],
  )
  NINJA_DEPS = <<~DEPS
    engine/CMakeFiles/inkflow_engine.dir/src/engine.cpp.o: #deps 2, deps mtime 1 (VALID)
        #{REPO_ROOT}/engine/src/engine.cpp
        #{BOOST_SOURCE}/boost/version.hpp
  DEPS

  def test_accepts_one_locked_cache_across_model_cache_and_compile_commands
    assert verify
  end

  def test_rejects_an_alternate_cache_in_the_active_cxx_model
    drifted = CXX_MODEL.sub(DEPENDENCY_CACHE, "/tmp/alternate")

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(cxx_model: drifted)
    end
  end

  def test_rejects_an_alternate_resolved_cmake_cache
    drifted = CMAKE_CACHE.sub(DEPENDENCY_CACHE, "/tmp/alternate")

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(cmake_cache: drifted)
    end
  end

  def test_rejects_an_unlocked_python_in_model_or_cache
    [
      {cxx_model: CXX_MODEL.sub(PYTHON_EXECUTABLE, "/tmp/python")},
      {cmake_cache: CMAKE_CACHE.sub(PYTHON_EXECUTABLE, "/tmp/python")},
    ].each do |override|
      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        verify(**override)
      end
    end
  end

  def test_rejects_an_injected_compiler_flag_in_the_active_cxx_model
    model = JSON.parse(CXX_MODEL)
    arguments = model.fetch("variant").fetch("buildSystemArgumentList")
    index = arguments.index("-DCMAKE_CXX_FLAGS=")
    arguments[index] = "-DCMAKE_CXX_FLAGS=-include /tmp/inject.hpp"

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(cxx_model: JSON.generate(model))
    end
  end

  def test_rejects_an_unrecognized_native_argument_in_the_active_cxx_model
    model = JSON.parse(CXX_MODEL)
    model.fetch("variant").fetch("buildSystemArgumentList") <<
      "-DCMAKE_PROJECT_INCLUDE=/tmp/inject.cmake"

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(cxx_model: JSON.generate(model))
    end
  end

  def test_rejects_variant_level_compiler_flags
    ["cFlagsList", "cppFlagsList"].each do |name|
      model = JSON.parse(CXX_MODEL)
      model.fetch("variant").fetch(name) << "-include /tmp/inject.hpp"

      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        verify(cxx_model: JSON.generate(model))
      end
    end
  end

  def test_rejects_an_initial_cache_or_project_include_in_final_arguments
    [
      "-C/tmp/preload.cmake",
      "-DCMAKE_PROJECT_INCLUDE=/tmp/inject.cmake",
    ].each do |argument|
      model = JSON.parse(CXX_MODEL)
      model.fetch("configurationArguments") << argument

      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        verify(cxx_model: JSON.generate(model))
      end
    end
  end

  def test_rejects_a_duplicate_last_wins_final_argument
    model = JSON.parse(CXX_MODEL)
    model.fetch("configurationArguments") << "-DANDROID_ABI=x86_64"

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(cxx_model: JSON.generate(model))
    end
  end

  def test_rejects_build_command_arguments_and_build_settings_environment
    with_build_args = JSON.parse(CXX_MODEL)
    with_build_args.fetch("cmake")["buildCommandArgs"] = "-- -d explain"
    with_environment = JSON.parse(CXX_MODEL)
    with_environment.fetch("buildSettings").fetch("environmentVariables") << {
      "name" => "CXXFLAGS",
      "value" => "-include /tmp/inject.hpp",
    }

    [with_build_args, with_environment].each do |model|
      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        verify(cxx_model: JSON.generate(model))
      end
    end
  end

  def test_rejects_wrong_cmake_ndk_and_toolchain_model_paths
    [
      CXX_MODEL.sub("#{CMAKE_ROOT}/bin/cmake", "/tmp/cmake"),
      CXX_MODEL.sub(NDK_ROOT, "/tmp/ndk"),
      CXX_MODEL.sub("#{CMAKE_ROOT}/bin/ninja", "/tmp/ninja"),
    ].each do |model|
      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        verify(cxx_model: model)
      end
    end
  end

  def test_rejects_an_injected_linker_flag_in_the_resolved_cmake_cache
    drifted = CMAKE_CACHE.sub(
      "CMAKE_SHARED_LINKER_FLAGS:STRING=",
      "CMAKE_SHARED_LINKER_FLAGS:STRING=-Wl,--whole-archive,/tmp/inject.a",
    )

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(cmake_cache: drifted)
    end
  end

  def test_rejects_a_nonempty_compiler_launcher_cache_row
    drifted = CMAKE_CACHE + "CMAKE_CXX_COMPILER_LAUNCHER:STRING=/tmp/inject\n"

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(cmake_cache: drifted)
    end
  end

  def test_rejects_native_control_paths_and_locked_toolchain_cache_drift
    [
      CMAKE_CACHE + "CMAKE_MODULE_PATH:STRING=/tmp/modules\n",
      CMAKE_CACHE + "CMAKE_PROJECT_InkFlow_INCLUDE:STRING=/tmp/inject.cmake\n",
      CMAKE_CACHE.sub("#{CMAKE_ROOT}/bin/ninja", "/tmp/ninja"),
      CMAKE_CACHE.sub("#{NDK_ROOT}/build/cmake/android.toolchain.cmake", "/tmp/toolchain.cmake"),
    ].each do |cache|
      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        verify(cmake_cache: cache)
      end
    end
  end

  def test_rejects_a_relevant_compile_command_without_the_verified_boost_tree
    commands = JSON.parse(COMPILE_COMMANDS)
    commands.last["command"] =
      "#{TOOLCHAIN_BIN}/clang++ -isystem /tmp/alternate -c rime_api.cc"

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(compile_commands: JSON.generate(commands))
    end
  end

  def test_rejects_a_competing_include_root_even_when_verified_boost_is_present
    commands = JSON.parse(COMPILE_COMMANDS)
    commands.first["arguments"].insert(1, "-I/tmp/alternate")

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(compile_commands: JSON.generate(commands))
    end
  end

  def test_rejects_a_forced_include_in_a_relevant_compile_command
    commands = JSON.parse(COMPILE_COMMANDS)
    commands.first.fetch("arguments").insert(1, "-include", "/tmp/inject.hpp")

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(compile_commands: JSON.generate(commands))
    end
  end

  def test_rejects_an_unlocked_compiler_or_ninja_dependency
    commands = JSON.parse(COMPILE_COMMANDS)
    commands.first.fetch("arguments")[0] = "/tmp/clang++"
    outside_dependency = NINJA_DEPS + "    /tmp/injected.hpp\n"

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(compile_commands: JSON.generate(commands))
    end
    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(ninja_deps: outside_dependency)
    end
  end

  def test_rejects_cmake_and_build_settings_files_before_build
    Dir.mktmpdir("inkflow-native-settings") do |root|
      assert InkFlow::AndroidNativeInputs.verify_forbidden_settings(root)

      File.write(File.join(root, "CMakeSettings.json"), "{}")
      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        InkFlow::AndroidNativeInputs.verify_forbidden_settings(root)
      end
      File.delete(File.join(root, "CMakeSettings.json"))
      File.symlink("missing", File.join(root, "BuildSettings.json"))
      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        InkFlow::AndroidNativeInputs.verify_forbidden_settings(root)
      end

      File.delete(File.join(root, "BuildSettings.json"))
      FileUtils.mkdir_p(File.join(root, "platforms", "android"))
      File.write(File.join(root, "platforms", "android", "local.properties"), "cmake.dir=/tmp\n")
      assert_raises(InkFlow::AndroidNativeInputs::Violation) do
        InkFlow::AndroidNativeInputs.verify_forbidden_settings(root)
      end
    end
  end

  def test_rejects_an_actual_boost_dependency_from_an_alternate_tree
    drifted = NINJA_DEPS.sub(BOOST_SOURCE, "/tmp/alternate")

    assert_raises(InkFlow::AndroidNativeInputs::Violation) do
      verify(ninja_deps: drifted)
    end
  end

  private

  def verify(
    cxx_model: CXX_MODEL,
    cmake_cache: CMAKE_CACHE,
    compile_commands: COMPILE_COMMANDS,
    ninja_deps: NINJA_DEPS
  )
    InkFlow::AndroidNativeInputs.verify(
      cxx_model_json: cxx_model,
      cmake_cache: cmake_cache,
      compile_commands_json: compile_commands,
      ninja_deps: ninja_deps,
      dependency_cache: DEPENDENCY_CACHE,
      boost_source: BOOST_SOURCE,
      repo_root: REPO_ROOT,
      sdk_root: SDK_ROOT,
      ndk_version: NDK_VERSION,
      cmake_version: CMAKE_VERSION,
      min_sdk: MIN_SDK,
      python_executable: PYTHON_EXECUTABLE,
    )
  end
end
