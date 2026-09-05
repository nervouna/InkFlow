#!/usr/bin/env ruby

require "json"
require "pathname"
require "shellwords"

module InkFlow
  module AndroidNativeInputs
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
    REQUIRED_BUILD_SYSTEM_ARGUMENTS = %w[
      -DANDROID_STL=c++_static
      -DBUILD_TESTING=OFF
      -DINKFLOW_BUILD_APPLE_PACKAGING_TOOLS=OFF
    ].freeze
    FORCED_INCLUDE_PREFIXES = %w[
      -include
      -imacros
    ].freeze

    class Violation < StandardError; end

    module_function

    def verify(
      cxx_model_json:,
      cmake_cache:,
      compile_commands_json:,
      ninja_deps:,
      dependency_cache:,
      boost_source:,
      repo_root:,
      sdk_root:,
      ndk_version:,
      cmake_version:,
      min_sdk:,
      python_executable:
    )
      dependency_cache = normalized_absolute_path(dependency_cache, "dependency cache")
      boost_source = normalized_absolute_path(boost_source, "Boost source")
      repo_root = normalized_absolute_path(repo_root, "repository root")
      sdk_root = normalized_absolute_path(sdk_root, "Android SDK root")
      ndk_root = "#{sdk_root}/ndk/#{ndk_version}"
      cmake_root = "#{sdk_root}/cmake/#{cmake_version}"
      python_executable = normalized_absolute_path(
        python_executable,
        "native-build Python executable",
      )
      unless path_within?(boost_source, dependency_cache)
        raise Violation, "Boost source must be inside the verified dependency cache"
      end

      build_directory = verify_compile_commands(
        compile_commands_json,
        boost_source: boost_source,
        repo_root: repo_root,
        ndk_root: ndk_root,
      )
      verify_cxx_model(
        cxx_model_json,
        dependency_cache: dependency_cache,
        repo_root: repo_root,
        build_directory: build_directory,
        ndk_root: ndk_root,
        cmake_root: cmake_root,
        cmake_version: String(cmake_version),
        min_sdk: String(min_sdk),
        python_executable: python_executable,
      )
      verify_cmake_cache(
        cmake_cache,
        dependency_cache: dependency_cache,
        ndk_root: ndk_root,
        cmake_root: cmake_root,
        python_executable: python_executable,
      )
      verify_ninja_dependencies(
        ninja_deps,
        boost_source: boost_source,
        build_directory: build_directory,
        repo_root: repo_root,
        ndk_root: ndk_root,
      )
      true
    rescue JSON::ParserError => error
      raise Violation, "invalid Android native build JSON: #{error.message}"
    rescue KeyError, TypeError => error
      raise Violation, "malformed Android native build metadata: #{error.message}"
    end

    def normalized_absolute_path(path, label)
      candidate = Pathname.new(String(path))
      raise Violation, "#{label} must be absolute" unless candidate.absolute?

      candidate.cleanpath.to_s
    end

    def path_within?(path, parent)
      path == parent || path.start_with?("#{parent}/")
    end

    def verify_forbidden_settings(repo_root)
      root = normalized_absolute_path(repo_root, "repository root")
      forbidden = [
        File.join(root, "CMakeSettings.json"),
        File.join(root, "BuildSettings.json"),
        File.join(root, "platforms", "android", "local.properties"),
      ].select { |path| File.exist?(path) || File.symlink?(path) }
      unless forbidden.empty?
        raise Violation,
          "Android build forbids local settings overrides: #{forbidden.join(", ")}"
      end
      true
    end

    def verify_cxx_model(
      json,
      dependency_cache:,
      repo_root:,
      build_directory:,
      ndk_root:,
      cmake_root:,
      cmake_version:,
      min_sdk:,
      python_executable:
    )
      model = JSON.parse(json)
      variant = model.fetch("variant")
      arguments = variant.fetch("buildSystemArgumentList")
      unless arguments.is_a?(Array) && arguments.all? { |argument| argument.is_a?(String) }
        raise Violation, "CXX model buildSystemArgumentList must be an array of strings"
      end

      required_build_system_arguments = REQUIRED_BUILD_SYSTEM_ARGUMENTS +
        ["-DPYTHON_EXECUTABLE=#{python_executable}"]
      expected_arguments = required_build_system_arguments +
        ["-DINKFLOW_DEPENDENCY_CACHE_DIR=#{dependency_cache}"] +
        LOCKED_EMPTY_CMAKE_INPUTS.map { |name| "-D#{name}=" }
      unless arguments.sort == expected_arguments.sort
        raise Violation,
          "active CXX model must contain exactly the locked native argument set"
      end

      %w[cFlagsList cppFlagsList].each do |name|
        flags = variant.fetch(name)
        unless flags == []
          raise Violation, "active CXX model #{name} must be an empty array"
        end
      end

      build_match = build_directory.match(
        %r{\A#{Regexp.escape(repo_root)}/platforms/android/app/\.cxx/RelWithDebInfo/([a-z0-9]+)/arm64-v8a\z},
      )
      unless build_match
        raise Violation, "active native build directory is outside the locked release layout"
      end
      build_hash = build_match[1]
      output_directory =
        "#{repo_root}/platforms/android/app/build/intermediates/cxx/" \
        "RelWithDebInfo/#{build_hash}/obj/arm64-v8a"
      toolchain_file = "#{ndk_root}/build/cmake/android.toolchain.cmake"
      ninja = "#{cmake_root}/bin/ninja"
      expected_configuration_arguments = [
        "-H#{repo_root}",
        "-DCMAKE_SYSTEM_NAME=Android",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        "-DCMAKE_SYSTEM_VERSION=#{min_sdk}",
        "-DANDROID_PLATFORM=android-#{min_sdk}",
        "-DANDROID_ABI=arm64-v8a",
        "-DCMAKE_ANDROID_ARCH_ABI=arm64-v8a",
        "-DANDROID_NDK=#{ndk_root}",
        "-DCMAKE_ANDROID_NDK=#{ndk_root}",
        "-DCMAKE_TOOLCHAIN_FILE=#{toolchain_file}",
        "-DCMAKE_MAKE_PROGRAM=#{ninja}",
        "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=#{output_directory}",
        "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=#{output_directory}",
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
        "-B#{build_directory}",
        "-GNinja",
      ] + required_build_system_arguments +
        ["-DINKFLOW_DEPENDENCY_CACHE_DIR=#{dependency_cache}"]
      configuration_arguments = model.fetch("configurationArguments")
      unless configuration_arguments.is_a?(Array) &&
          configuration_arguments.all? { |argument| argument.is_a?(String) } &&
          configuration_arguments.sort == expected_configuration_arguments.sort
        raise Violation,
          "active CXX model must contain exactly the locked final CMake arguments"
      end

      expected_effective_cmake = {
        "effectiveConfiguration" => {
          "inheritEnvironments" => [],
          "variables" => [],
        },
      }
      unless model.fetch("cmake") == expected_effective_cmake
        raise Violation, "active CXX model contains an effective CMake settings override"
      end
      unless model.fetch("buildSettings") == {"environmentVariables" => []}
        raise Violation, "active CXX model contains a BuildSettings environment override"
      end

      module_model = variant.fetch("module")
      expected_module_paths = {
        "cmakeToolchainFile" => toolchain_file,
        "makeFile" => "#{repo_root}/CMakeLists.txt",
        "moduleRootFolder" => "#{repo_root}/platforms/android/app",
        "ndkFolder" => ndk_root,
        "ndkFolderBeforeSymLinking" => ndk_root,
        "ninjaExe" => ninja,
      }
      expected_module_paths.each do |name, expected|
        unless module_model.fetch(name) == expected
          raise Violation, "active CXX model #{name} does not match the locked path"
        end
      end
      expected_cmake_model = {
        "cmakeExe" => "#{cmake_root}/bin/cmake",
        "cmakeVersionFromDsl" => cmake_version,
      }
      unless module_model.fetch("cmake") == expected_cmake_model
        raise Violation, "active CXX model CMake executable does not match the locked SDK path"
      end
    end

    def verify_cmake_cache(
      cache,
      dependency_cache:,
      ndk_root:,
      cmake_root:,
      python_executable:
    )
      expected = "INKFLOW_DEPENDENCY_CACHE_DIR:PATH=#{dependency_cache}"
      cache_rows = cache.each_line.filter do |line|
        line.start_with?("INKFLOW_DEPENDENCY_CACHE_DIR:")
      end.map(&:strip)
      unless cache_rows == [expected]
        raise Violation,
          "active CMake cache must resolve exactly to the locked dependency cache: #{expected}"
      end

      LOCKED_EMPTY_CMAKE_FLAGS.each do |name|
        rows = cache.each_line.filter { |line| line.start_with?("#{name}:") }
        values = rows.map { |line| line.split("=", 2).fetch(1, nil)&.strip }
        unless values == [""]
          raise Violation, "active CMake cache input #{name} must exist exactly once and be empty"
        end
      end
      LOCKED_EMPTY_CMAKE_LAUNCHERS.each do |name|
        values = cmake_cache_values(cache, name)
        unless values.empty? || values == [""]
          raise Violation, "active CMake launcher #{name} must be absent or empty"
        end
      end
      LOCKED_EMPTY_CMAKE_PATHS.each do |name|
        values = cmake_cache_values(cache, name)
        unless values.empty? || values == [""]
          raise Violation, "active CMake control input #{name} must be absent or empty"
        end
      end

      {
        "CMAKE_MAKE_PROGRAM" => "#{cmake_root}/bin/ninja",
        "CMAKE_TOOLCHAIN_FILE" => "#{ndk_root}/build/cmake/android.toolchain.cmake",
        "PYTHON_EXECUTABLE" => python_executable,
      }.each do |name, expected_value|
        values = cmake_cache_values(cache, name)
        unless values == [expected_value]
          raise Violation, "active CMake cache #{name} does not match the locked toolchain path"
        end
      end
    end

    def cmake_cache_values(cache, name)
      cache.each_line.filter { |line| line.start_with?("#{name}:") }
        .map { |line| line.split("=", 2).fetch(1, nil)&.strip }
    end

    def verify_compile_commands(json, boost_source:, repo_root:, ndk_root:)
      commands = JSON.parse(json)
      unless commands.is_a?(Array)
        raise Violation, "compile_commands.json must contain an array"
      end

      source_roots = [
        "#{repo_root}/engine",
        "#{repo_root}/third_party/librime/src",
      ]
      relevant_count = 0
      build_directories = []
      commands.each do |entry|
        directory = normalized_absolute_path(entry.fetch("directory"), "compile directory")
        source = normalized_compile_source(entry.fetch("file"), directory)
        arguments = command_arguments(entry)
        verify_locked_compiler(arguments, source, ndk_root)
        verify_no_forced_includes(arguments, source)
        next unless source_roots.any? { |root| path_within?(source, root) }

        relevant_count += 1
        build_directories << directory
        include_paths = compiler_include_paths(arguments, directory)
        unless include_paths.include?(boost_source)
          raise Violation,
            "native compile command for #{source} does not include verified Boost source #{boost_source}"
        end
        unexpected = include_paths.uniq - allowed_include_paths(
          repo_root: repo_root,
          build_directory: directory,
          boost_source: boost_source,
        )
        unless unexpected.empty?
          raise Violation,
            "native compile command for #{source} contains unverified include roots: #{unexpected.join(", ")}"
        end
      end

      if relevant_count.zero?
        raise Violation, "compile_commands.json contains no InkFlow engine or librime sources"
      end
      build_directories.uniq.tap do |directories|
        unless directories.length == 1
          raise Violation, "relevant native compile commands must share one build directory"
        end
      end.fetch(0)
    end

    def allowed_include_paths(repo_root:, build_directory:, boost_source:)
      [
        boost_source,
        "#{repo_root}/engine/include",
        "#{repo_root}/engine/src",
        "#{repo_root}/third_party/librime/include",
        "#{repo_root}/third_party/librime/src",
        "#{repo_root}/third_party/librime/deps/leveldb/include",
        "#{repo_root}/third_party/librime/deps/marisa-trie/include",
        "#{repo_root}/third_party/librime/deps/opencc/src",
        "#{repo_root}/third_party/librime/deps/yaml-cpp/include",
        "#{build_directory}/engine/third-party/librime/src",
        "#{build_directory}/engine/third-party/opencc-include",
      ].map { |path| Pathname.new(path).cleanpath.to_s }.freeze
    end

    def verify_ninja_dependencies(
      report,
      boost_source:,
      build_directory:,
      repo_root:,
      ndk_root:
    )
      dependencies = report.each_line.map do |line|
        next unless line.match?(/^\s+/)

        dependency = line.strip
        next if dependency.empty?

        candidate = Pathname.new(dependency)
        candidate = Pathname.new(build_directory).join(candidate) unless candidate.absolute?
        candidate.cleanpath.to_s
      end.compact
      boost_dependencies = dependencies.select { |path| path.include?("/boost/") }
      if boost_dependencies.empty?
        raise Violation, "Ninja dependency graph contains no resolved Boost headers"
      end

      unexpected = boost_dependencies.uniq.reject do |dependency|
        path_within?(dependency, boost_source)
      end
      unless unexpected.empty?
        raise Violation,
          "Ninja resolved Boost headers outside the verified source tree: #{unexpected.join(", ")}"
      end

      outside_trust_boundary = dependencies.uniq.reject do |dependency|
        path_within?(dependency, repo_root) || path_within?(dependency, ndk_root)
      end
      unless outside_trust_boundary.empty?
        raise Violation,
          "Ninja resolved inputs outside the repository and locked NDK: " \
          "#{outside_trust_boundary.join(", ")}"
      end
    end

    def normalized_compile_source(source, directory)
      candidate = Pathname.new(String(source))
      candidate = Pathname.new(directory).join(candidate) unless candidate.absolute?
      candidate.cleanpath.to_s
    end

    def command_arguments(entry)
      if entry.key?("arguments")
        arguments = entry.fetch("arguments")
        unless arguments.is_a?(Array) && arguments.all? { |argument| argument.is_a?(String) }
          raise Violation, "compile command arguments must be an array of strings"
        end
        arguments
      elsif entry.key?("command")
        Shellwords.split(String(entry.fetch("command")))
      else
        raise Violation, "compile command is missing arguments and command"
      end
    rescue ArgumentError => error
      raise Violation, "invalid compile command quoting: #{error.message}"
    end

    def compiler_include_paths(arguments, directory)
      paths = []
      index = 0
      while index < arguments.length
        argument = arguments[index]
        include_path = nil
        if ["-I", "-isystem", "-iquote", "-idirafter"].include?(argument)
          index += 1
          raise Violation, "#{argument} is missing its include path" if index >= arguments.length
          include_path = arguments[index]
        elsif argument.start_with?("-I") && argument.length > 2
          include_path = argument.delete_prefix("-I")
        elsif argument.start_with?("-isystem") && argument.length > 8
          include_path = argument.delete_prefix("-isystem")
        elsif argument.start_with?("-iquote") && argument.length > 7
          include_path = argument.delete_prefix("-iquote")
        elsif argument.start_with?("-idirafter") && argument.length > 10
          include_path = argument.delete_prefix("-idirafter")
        end

        if include_path
          candidate = Pathname.new(include_path)
          candidate = Pathname.new(directory).join(candidate) unless candidate.absolute?
          paths << candidate.cleanpath.to_s
        end
        index += 1
      end
      paths
    end

    def verify_no_forced_includes(arguments, source)
      injected = arguments.find do |argument|
        FORCED_INCLUDE_PREFIXES.any? { |prefix| argument.start_with?(prefix) }
      end
      return unless injected

      raise Violation,
        "native compile command for #{source} contains a forced include option: #{injected}"
    end

    def verify_locked_compiler(arguments, source, ndk_root)
      extension = File.extname(source)
      compiler = extension == ".c" ? "clang" : "clang++"
      expected = "#{ndk_root}/toolchains/llvm/prebuilt/darwin-x86_64/bin/#{compiler}"
      unless arguments.first == expected
        raise Violation,
          "native compile command for #{source} does not use locked compiler #{expected}"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "settings"
    unless ARGV.length == 2
      abort "usage: #{$PROGRAM_NAME} settings REPO_ROOT"
    end
    begin
      InkFlow::AndroidNativeInputs.verify_forbidden_settings(ARGV.fetch(1))
    rescue InkFlow::AndroidNativeInputs::Violation => error
      warn "error: #{error.message}"
      exit 1
    end
    puts "PASS no local Android or native settings override"
    exit 0
  elsif ARGV.length != 12
    abort "usage: #{$PROGRAM_NAME} CXX_MODEL CMAKE_CACHE COMPILE_COMMANDS NINJA_DEPS DEPENDENCY_CACHE BOOST_SOURCE REPO_ROOT SDK_ROOT NDK_VERSION CMAKE_VERSION MIN_SDK PYTHON_EXECUTABLE"
  end

  cxx_model_path, cmake_cache_path, compile_commands_path, ninja_deps_path,
    dependency_cache, boost_source, repo_root, sdk_root, ndk_version,
    cmake_version, min_sdk, python_executable = ARGV
  begin
    InkFlow::AndroidNativeInputs.verify(
      cxx_model_json: File.read(cxx_model_path),
      cmake_cache: File.read(cmake_cache_path),
      compile_commands_json: File.read(compile_commands_path),
      ninja_deps: File.read(ninja_deps_path),
      dependency_cache: dependency_cache,
      boost_source: boost_source,
      repo_root: repo_root,
      sdk_root: sdk_root,
      ndk_version: ndk_version,
      cmake_version: cmake_version,
      min_sdk: min_sdk,
      python_executable: python_executable,
    )
  rescue InkFlow::AndroidNativeInputs::Violation => error
    warn "error: #{error.message}"
    exit 1
  end

  puts "PASS Android native build inputs resolve to the locked toolchain and verified source trees"
end
