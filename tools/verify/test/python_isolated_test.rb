#!/usr/bin/env ruby

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class PythonIsolatedTest < Minitest::Test
  LAUNCHER = File.expand_path("../../build/python-isolated", __dir__)

  def setup
    @root = Dir.mktmpdir("inkflow-python-isolated")
    @home = File.join(@root, "home")
    @working_directory = File.join(@root, "working")
    @python_path = File.join(@root, "python-path")
    @script_directory = File.join(@root, "scripts")
    @marker = File.join(@root, "startup-hook-ran")
    FileUtils.mkdir_p(
      [@home, @working_directory, @python_path, @script_directory],
    )

    hostile_hook = <<~PYTHON
      from pathlib import Path
      import os
      Path(os.environ["INKFLOW_PYTHON_HOOK_MARKER"]).write_text("executed")
    PYTHON
    [@working_directory, @python_path, @script_directory].each do |directory|
      File.write(File.join(directory, "sitecustomize.py"), hostile_hook)
      File.write(File.join(directory, "usercustomize.py"), hostile_hook)
    end

    user_site = File.join(
      @home,
      "Library/Python/3.9/lib/python/site-packages",
    )
    FileUtils.mkdir_p(user_site)
    File.write(
      File.join(user_site, "inkflow-hostile.pth"),
      "import os, pathlib; pathlib.Path(os.environ['INKFLOW_PYTHON_HOOK_MARKER']).write_text('executed')\n",
    )
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def test_c_expression_runs_without_site_or_environment_startup_hooks
    output, error, status = run_launcher(
      "-c",
      "import sys; assert sys.flags.isolated == 1; " \
        "assert sys.flags.no_site == 1; print('isolated')",
    )

    assert status.success?, error
    assert_equal "isolated\n", output
    refute File.exist?(@marker)
  end

  def test_script_can_import_a_verified_sibling_without_running_hooks
    File.write(File.join(@script_directory, "helper.py"), "VALUE = 'sibling-ok'\n")
    script = File.join(@script_directory, "main.py")
    output = File.join(@root, "script-output")
    File.write(
      script,
      <<~PYTHON,
        from pathlib import Path
        import sys
        from helper import VALUE
        Path(sys.argv[1]).write_text(VALUE)
      PYTHON
    )

    _stdout, error, status = run_launcher(script, output)

    assert status.success?, error
    assert_equal "sibling-ok", File.read(output)
    refute File.exist?(@marker)
  end

  private

  def run_launcher(*arguments)
    environment = {
      "HOME" => @home,
      "INKFLOW_PYTHON_HOOK_MARKER" => @marker,
      "PYTHONPATH" => @python_path,
      "PYTHONUSERBASE" => @home,
    }
    Open3.capture3(
      environment,
      LAUNCHER,
      *arguments,
      chdir: @working_directory,
    )
  end
end
