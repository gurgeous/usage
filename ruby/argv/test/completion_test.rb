require "json"
require "open3"
require_relative "test_helper"

class CompletionTest < Minitest::Test
  USAGE = ENV.fetch("USAGE_BIN", File.expand_path("../../../target/debug/usage", __dir__))

  def test_completion_corpus
    Dir[File.expand_path("../../../corpus/complete/*.json", __dir__)].sort.each do |path|
      JSON.parse(File.read(path)).fetch("vectors").each do |vector|
        cli = generate(vector.fetch("spec"), "Completion#{vector.fetch("id").hash.abs}")
        answer = cli::COMPLETER.answer(
          vector.fetch("line"),
          cursor: vector["cursor"],
          shell: :bash
        )
        expect = vector.fetch("expect")
        actual = answer.candidates.map(&:value)
        expected = expect.fetch("candidates")

        assert_equal expected.sort, actual.sort, vector.fetch("id")
        assert_equal expect.fetch("files", false), !answer.files.nil?, vector.fetch("id")
      end
    end
  end

  def test_generated_completion_request
    cli = generate("name \"ex\"\nbin \"ex\"\ncmd \"install\" help=\"Install things\" {}\n", "CompletionRequest")

    assert_nil cli.complete(%w[install])
    assert_equal "install\n", cli.complete(%w[__complete_word__ --line ex\ ])
    assert_equal "Install things", cli::COMPLETER.answer("ex ").candidates.first.description
    assert_includes cli.completion_script(:bash), "ex __complete_word__ --shell bash"
  end

  def test_completion_types_follow_reference_lookup_order
    cli = generate(<<~KDL, "CompletionTypes")
      name "ex"
      bin "ex"
      complete "key" type="file"
      cmd "get" {
        arg "<KEY>"
        complete "key" type="dir"
      }
      cmd "set" {
        flag "--output <DEST>"
        complete "dest" type="dir"
      }
    KDL

    assert_equal :any, cli::COMPLETER.answer("ex get ").files
    assert_equal :dirs, cli::COMPLETER.answer("ex set --output ").files
  end

  def test_extension_completion_types_preserve_the_filter
    cli = generate(<<~KDL, "CompletionExtensions")
      name "ex"
      bin "ex"
      arg "<FILE>"
      complete "file" type="path:toml, .yaml,."
    KDL

    files = cli::COMPLETER.answer("ex ").files
    assert_instance_of Usage::Complete::ExtensionFiles, files
    assert_equal %w[toml yaml], files.extensions
  end

  def test_separator_stops_flag_completion
    cli = generate(<<~KDL, "CompletionSeparator")
      name "ex"
      bin "ex"
      flag "--verbose" global=#true
      cmd "run" {
        flag "--shell <SHELL>"
      }
    KDL

    assert_empty values(cli, "ex run -- -")
  end

  def test_help_topics_offer_commands_and_aliases_only
    cli = generate(<<~KDL, "CompletionHelpTopic")
      name "ex"
      bin "ex"
      flag "--verbose"
      cmd "run" {
        alias "r"
      }
      cmd "list" {}
    KDL

    assert_equal %w[list r run], values(cli, "ex help ").sort
  end

  def test_double_dash_argument_waits_for_separator
    cli = generate(<<~KDL, "CompletionDoubleDash")
      name "ex"
      bin "ex"
      arg "[REST]" double_dash=required {
        choices "one" "two"
      }
    KDL

    assert_empty values(cli, "ex ")
    assert_equal %w[one two], values(cli, "ex -- ")
  end

  def test_nearer_flag_withdraws_only_its_claimed_spelling
    cli = generate(<<~KDL, "CompletionClaimedSpelling")
      name "ex"
      bin "ex"
      flag "-j --jobs --workers" global=#true
      cmd "run" {
        flag "--jobs"
      }
    KDL

    assert_equal %w[--jobs --workers -j], values(cli, "ex run -").sort
  end

  def test_hidden_flag_aliases_bind_but_do_not_complete
    cli = generate(<<~KDL, "CompletionHiddenFlagAliases")
      name "ex"
      bin "ex"
      flag "-o --output" {
        alias "-q" hide=#true
        alias "--quietly" hide=#true
      }
    KDL

    assert cli.parse(["-q"]).output
    assert cli.parse(["--quietly"]).output
    assert_equal %w[--output -o], values(cli, "ex -").sort
  end

  def test_hidden_command_alias_binds_but_does_not_complete
    cli = generate(<<~KDL, "CompletionHiddenCommandAlias")
      name "ex"
      bin "ex"
      cmd "run" {
        alias "r"
        alias "hidden-run" hide=#true
      }
    KDL

    refute_nil cli.parse(["hidden-run"]).run
    assert_equal %w[r run], values(cli, "ex ").sort
  end

  def test_long_form_beats_a_nearer_negation
    cli = generate(<<~KDL, "CompletionLongBeatsNegation")
      name "ex"
      bin "ex"
      flag "--no-color" global=#true
      cmd "run" {
        flag "--color" negate="--no-color"
      }
    KDL

    assert_equal 1, values(cli, "ex run -").count("--no-color")
  end

  def test_inherited_negation_survives_shadowed_positive_form
    cli = generate(<<~KDL, "CompletionInheritedNegation")
      name "ex"
      bin "ex"
      flag "--color" negate="--no-color" global=#true
      cmd "run" {
        flag "--color"
      }
    KDL

    offered = values(cli, "ex run -")
    assert_includes offered, "--no-color"
    assert_equal 1, offered.count("--color")
  end

  def test_subcommand_is_not_offered_after_a_positional
    cli = generate(<<~KDL, "CompletionFilledPositional")
      name "ex"
      bin "ex"
      arg "[file]"
      cmd "run" {}
    KDL

    assert_includes values(cli, "ex "), "run"
    refute_includes values(cli, "ex a.txt "), "run"
  end

  def test_negation_matching_its_long_form_is_offered_once
    cli = generate(<<~KDL, "CompletionRepeatedNegation")
      name "ex"
      bin "ex"
      flag "--no-color" negate="--no-color"
    KDL

    assert_equal 1, values(cli, "ex -").count("--no-color")
  end

  def test_variadic_flag_still_collecting_offers_values_and_flags
    cli = generate(<<~KDL, "CompletionVariadicFlag")
      name "ex"
      bin "ex"
      flag "--tools <TOOL>..." {
        choices "node" "python"
      }
      flag "--force"
      cmd "run" {}
    KDL

    assert_includes values(cli, "ex --tools a "), "node"
    assert_includes values(cli, "ex --tools a -"), "--force"
    refute_includes values(cli, "ex --tools a "), "run"
    refute_includes values(cli, "ex --tools -"), "--force"
  end

  def test_nearer_flag_takes_a_spelling_from_an_inherited_negation
    cli = generate(<<~KDL, "CompletionNearerNegation")
      name "ex"
      bin "ex"
      flag "--x" negate="--x" global=#true
      cmd "run" {
        flag "--x"
      }
    KDL

    assert_equal 1, values(cli, "ex run -").count("--x")
  end

  private

  def generate(spec, name)
    source, stderr, status = Open3.capture3(USAGE, "generate", "ruby", "--spec", spec, "--module", name)
    raise stderr unless status.success?

    eval(source, TOPLEVEL_BINDING, "#{name}.rb") # standard:disable Security/Eval
    Object.const_get(name)
  end

  def values(cli, line)
    cli::COMPLETER.answer(line).candidates.map(&:value)
  end
end
