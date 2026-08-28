require "open3"
require_relative "test_helper"

class GeneratedTest < Minitest::Test
  USAGE = ENV.fetch("USAGE_BIN", File.expand_path("../../../target/debug/usage", __dir__))

  def test_generated_typed_results
    cli = generate(<<~KDL, "GeneratedTyped")
      name "ex"
      bin "ex"
      flag "-v --verbose"
      flag "--include <item>" var=#true
      cmd "install" {
        arg "<package>"
      }
    KDL

    result = cli.parse(%w[-v --include a --include b install rack])

    assert result.verbose
    assert_equal %w[a b], result.include
    assert_equal "rack", result.install.package
  end

  def test_generated_external_result
    cli = generate(<<~KDL, "GeneratedExternal")
      name "ex"
      bin "ex"
      external_subcommand #true
    KDL

    assert_equal %w[tool --help], cli.parse(%w[tool --help]).external
  end

  def test_generated_external_result_uses_a_collision_safe_field
    cli = generate(<<~KDL, "GeneratedExternalCollision")
      name "ex"
      bin "ex"
      external_subcommand #true
      flag "--external"
    KDL

    result = cli.parse(["tool"])
    assert_equal false, result.external
    assert_equal ["tool"], result.external_external
  end

  def test_generated_multicall_result
    cli = generate(<<~KDL, "GeneratedMulticall")
      name "busybox"
      bin "busybox"
      multicall #true
      cmd "ls" {
        flag "-l --long"
      }
    KDL

    assert cli.parse(["-l"], argv0: "/usr/bin/ls").ls.long
  end

  private

  def generate(spec, name)
    source, stderr, status = Open3.capture3(USAGE, "generate", "ruby", "--spec", spec, "--module", name)
    raise stderr unless status.success?

    eval(source, TOPLEVEL_BINDING, "#{name}.rb") # standard:disable Security/Eval
    Object.const_get(name)
  end
end
