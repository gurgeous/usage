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

  def test_generated_help_uses_reference_pages
    cli = generate(<<~KDL, "GeneratedHelp")
      name "ex"
      bin "ex"
      about "Short root help"
      long_about "Long root help"
      flag "--help-all" action="help_all"
      cmd "zulu" {}
      cmd "early" display_order=1 {}
      cmd "hidden" hide=#true {}
    KDL

    short = assert_raises(Usage::Help) { cli.parse(["-h"]) }
    long = assert_raises(Usage::Help) { cli.parse(["--help"]) }
    all = assert_raises(Usage::Help) { cli.parse(["--help-all"]) }

    assert_equal cli::HELP.fetch(cli::CMD_ROOT, long: false), short.message
    assert_equal cli::HELP.fetch(cli::CMD_ROOT, long: true), long.message
    assert_includes short.message, "Short root help"
    assert_includes long.message, "Long root help"
    assert_operator all.message.index("Usage: ex early"), :<, all.message.index("Usage: ex zulu")
    refute_includes all.message, "Usage: ex hidden"
  end

  def test_generated_usage_line_hides_entries
    cli = generate(<<~KDL, "GeneratedHiddenUsage")
      name "ex"
      bin "ex"
      flag "--shown"
      flag "--secret" hide=#true
      arg "[visible]"
      arg "[buried]" hide=#true
    KDL
    line = usage_line(cli)

    assert_includes line, "--shown"
    assert_includes line, "visible"
    refute_includes line, "secret"
    refute_includes line, "buried"
  end

  def test_generated_root_usage_line_is_recognizable
    cli = generate("name \"ex\"\nbin \"ex\"\ncmd \"run\" {}\n", "GeneratedRootUsage")

    assert_equal "Usage: ex <SUBCOMMAND>", usage_line(cli)
  end

  def test_generated_flag_value_uses_its_own_requiredness
    cases = {
      'flag "--tool <TOOL>"' => "Usage: ex [--tool <TOOL>]",
      'flag "--v <n>" required=#true' => "Usage: ex <--v <n>>",
      'flag "--opt [n]"' => "Usage: ex [--opt [n]]",
      "flag \"--jobs <n>\" required=#true {\n  arg \"<n>\" default=\"4\"\n}" => "Usage: ex <--jobs [n]>"
    }

    cases.each_with_index do |(declaration, expected), index|
      cli = generate("name \"ex\"\nbin \"ex\"\n#{declaration}\n", "GeneratedFlagUsage#{index}")
      assert_equal expected, usage_line(cli), declaration
    end
  end

  def test_generated_relationships_point_at_real_entries
    cli = generate(<<~KDL, "GeneratedRelationships")
      name "ex"
      bin "ex"
      flag "--trigger"
      flag "--fallback"
      flag "--needed" required_if="--trigger"
      flag "--unless" required_unless="--fallback"
      flag "--mode <MODE>"
      flag "--scope <SCOPE>"
      flag "--token <TOKEN>" {
        required_if_eq "--mode" "remote"
      }
      flag "--all <ALL>" {
        required_if_eq_all "--mode" "remote" "--scope" "global"
      }
      flag "--format <FORMAT>" {
        requires_if "json" "--schema"
      }
      flag "--schema <SCHEMA>"
      flag "--conditional" {
        default_if "--trigger" "true"
      }
    KDL
    entries = cli::META.entries.compact

    %i[required_if required_unless].each do |field|
      references = entries.flat_map { _1.fetch(field, []) }
      refute_empty references, field
      references.each { refute_nil cli::META[_1], "#{field} points at missing key #{_1}" }
    end
    %i[default_if required_if_eq required_if_eq_all requires_if].each do |field|
      references = entries.flat_map { _1.fetch(field, []) }
      refute_empty references, field
      references.each { refute_nil cli::META[_1[:key]], "#{field} points at missing key #{_1[:key]}" }
    end
  end

  private

  def generate(spec, name)
    source, stderr, status = Open3.capture3(USAGE, "generate", "ruby", "--spec", spec, "--module", name)
    raise stderr unless status.success?

    eval(source, TOPLEVEL_BINDING, "#{name}.rb") # standard:disable Security/Eval
    Object.const_get(name)
  end

  # one-liners

  def usage_line(cli)
    cli::HELP.fetch(cli::CMD_ROOT, long: false).lines.find { _1.start_with?("Usage: ") }.strip
  end
end
