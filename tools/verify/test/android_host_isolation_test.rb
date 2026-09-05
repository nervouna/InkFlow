#!/usr/bin/env ruby

require "fileutils"
require "minitest/autorun"
require "open3"
require "shellwords"
require "tmpdir"

class AndroidHostIsolationTest < Minitest::Test
  REPO_ROOT = File.expand_path("../../..", __dir__)
  SCRIPT = File.expand_path("../android.sh", __dir__)
  SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

  def setup
    @root = Dir.mktmpdir("inkflow-android-host-isolation")
    @home = File.join(@root, "home")
    @hostile_bin = File.join(@root, "bin")
    @zsh_directory = File.join(@root, "zsh")
    @zsh_marker = File.join(@root, "zsh-hook-ran")
    @ruby_marker = File.join(@root, "ruby-hook-ran")
    @rubygems_marker = File.join(@root, "rubygems-plugin-ran")
    @perl_marker = File.join(@root, "perl-module-ran")
    @git_marker = File.join(@root, "git-fsmonitor-ran")
    @path_marker = File.join(@root, "hostile-path-command-ran")
    FileUtils.mkdir_p([@home, @hostile_bin, @zsh_directory])

    File.write(
      File.join(@zsh_directory, ".zshenv"),
      "print -r -- triggered > #{Shellwords.escape(@zsh_marker)}\n",
    )
    @ruby_hook = File.join(@root, "ruby-hook.rb")
    File.write(
      @ruby_hook,
      "File.write(#{@ruby_marker.dump}, 'triggered')\n",
    )
    create_rubygems_plugin
    create_perl_module
    create_git_fsmonitor_hook
    create_hostile_path_commands
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def test_hostile_user_configuration_is_not_loaded
    prove_hostile_rubygems_plugin_is_live
    prove_hostile_perl_module_is_live
    prove_hostile_git_hook_is_live

    environment = {
      "APKANALYZER_OPTS" => "-javaagent:#{File.join(@root, "hostile.jar")}",
      "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"),
      "GEM_HOME" => File.join(@root, "gems"),
      "GEM_PATH" => File.join(@root, "gems"),
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_GLOBAL" => File.join(@home, ".gitconfig"),
      "GIT_CONFIG_KEY_0" => "core.fsmonitor",
      "GIT_CONFIG_SYSTEM" => File.join(@home, ".gitconfig"),
      "GIT_CONFIG_VALUE_0" => @git_hook,
      "GREP_OPTIONS" => "-v",
      "HOME" => @home,
      "JAVA_HOME" => File.join(@root, "hostile-java-home"),
      "JAVA_OPTS" => "-javaagent:#{File.join(@root, "hostile.jar")}",
      "JAVA_TOOL_OPTIONS" => "-javaagent:#{File.join(@root, "hostile.jar")}",
      "JDK_JAVA_OPTIONS" => "-javaagent:#{File.join(@root, "hostile.jar")}",
      "PATH" => "#{@hostile_bin}:#{SYSTEM_PATH}",
      "PERLLIB" => @perl_root,
      "RUBYGEMS_LOAD_ALL_PLUGINS" => "1",
      "RUBYLIB" => @root,
      "RUBYOPT" => "-r#{@ruby_hook}",
      "UNZIP" => "-z",
      "UNZIPOPT" => "-z",
      "ZIPINFO" => "-x org/gradle/wrapper/GradleWrapperMain.class",
      "ZDOTDIR" => @zsh_directory,
    }

    output, error, status = Open3.capture3(
      environment,
      SCRIPT,
      "--host-isolation-probe",
    )

    assert status.success?, error
    assert_empty error
    assert_includes output, "PASS Android verification host is isolated"
    refute File.exist?(@zsh_marker)
    refute File.exist?(@ruby_marker)
    refute File.exist?(@rubygems_marker)
    refute File.exist?(@perl_marker)
    refute File.exist?(@git_marker)
    refute File.exist?(@path_marker)
  end

  private

  def create_rubygems_plugin
    gem_root = File.join(@home, ".gem", "ruby", "2.6.0")
    plugin_root = File.join(gem_root, "gems", "hostile-plugin-1.0.0")
    FileUtils.mkdir_p([
      File.join(plugin_root, "lib"),
      File.join(gem_root, "specifications"),
    ])
    File.write(
      File.join(plugin_root, "lib", "rubygems_plugin.rb"),
      "File.write(#{@rubygems_marker.dump}, 'triggered')\n",
    )
    File.write(
      File.join(gem_root, "specifications", "hostile-plugin-1.0.0.gemspec"),
      <<~RUBY,
        Gem::Specification.new do |spec|
          spec.name = "hostile-plugin"
          spec.version = "1.0.0"
          spec.summary = "Isolation test plugin"
          spec.authors = ["InkFlow"]
          spec.files = ["lib/rubygems_plugin.rb"]
          spec.require_paths = ["lib"]
        end
      RUBY
    )
  end

  def create_git_fsmonitor_hook
    @git_hook = File.join(@root, "git-fsmonitor")
    File.write(
      @git_hook,
      <<~SH,
        #!/bin/sh
        printf '%s\n' triggered > #{Shellwords.escape(@git_marker)}
        printf '%s\n' inkflow-test-token
      SH
    )
    FileUtils.chmod(0o755, @git_hook)
    File.write(
      File.join(@home, ".gitconfig"),
      <<~CONFIG,
        [core]
          fsmonitor = #{@git_hook}
      CONFIG
    )
  end

  def create_perl_module
    @perl_root = File.join(@root, "perl")
    module_directory = File.join(@perl_root, "Digest")
    FileUtils.mkdir_p(module_directory)
    File.write(
      File.join(module_directory, "SHA.pm"),
      <<~PERL,
        package Digest::SHA;
        BEGIN {
          open my $marker, ">", #{@perl_marker.dump} or die $!;
          print {$marker} "triggered";
          close $marker;
        }
        die "hostile Digest::SHA loaded";
      PERL
    )
  end

  def create_hostile_path_commands
    %w[env git grep ruby shasum unzip].each do |command|
      path = File.join(@hostile_bin, command)
      File.write(
        path,
        <<~SH,
          #!/bin/sh
          printf '%s\n' #{command} > #{Shellwords.escape(@path_marker)}
          exit 97
        SH
      )
      FileUtils.chmod(0o755, path)
    end
  end

  def prove_hostile_rubygems_plugin_is_live
    _output, error, status = Open3.capture3(
      { "HOME" => @home, "PATH" => SYSTEM_PATH },
      "/usr/bin/ruby",
      "-rrubygems",
      "-e",
      "Gem.load_plugins",
      unsetenv_others: true,
    )
    assert status.success?, error
    assert File.exist?(@rubygems_marker),
           "hostile RubyGems plugin fixture did not execute"
    FileUtils.rm_f(@rubygems_marker)
  end

  def prove_hostile_git_hook_is_live
    _output, error, status = Open3.capture3(
      { "GIT_OPTIONAL_LOCKS" => "0", "HOME" => @home, "PATH" => SYSTEM_PATH },
      "/usr/bin/git",
      "-C",
      REPO_ROOT,
      "status",
      "--porcelain=v1",
      "--untracked-files=no",
      unsetenv_others: true,
    )
    assert status.success?, error
    assert File.exist?(@git_marker), "hostile Git fsmonitor fixture did not execute"
    FileUtils.rm_f(@git_marker)
  end

  def prove_hostile_perl_module_is_live
    Open3.capture3(
      { "PATH" => SYSTEM_PATH, "PERLLIB" => @perl_root },
      "/usr/bin/shasum",
      "-a",
      "256",
      unsetenv_others: true,
    )
    assert File.exist?(@perl_marker), "hostile Perl module fixture did not execute"
    FileUtils.rm_f(@perl_marker)
  end
end
