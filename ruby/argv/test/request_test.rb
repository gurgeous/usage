require "open3"
require_relative "test_helper"

class RequestTest < Minitest::Test
  USAGE = ENV.fetch("USAGE_BIN", File.expand_path("../../../target/debug/usage", __dir__))

  def test_request_options_and_fallbacks
    cli = generate(<<~KDL, "RequestOptions")
      name "ex"
      bin "ex"
      cmd "use" {
        cmd "north" {}
      }
    KDL

    zsh = cli.complete(%w[__complete_word__ --shell zsh --line ex\ use\ no --cursor 6])
    assert_includes zsh, "use\t"
    assert_equal "north\n", cli.complete(%w[__complete_word__ --wat 1 --shell klingon --line ex\ use\ ])
    assert_equal "north\n", cli.complete(["__complete_word__", "--line", "ex use ", "--cursor", "nope"])
  end

  def test_path_fallback_at_each_position
    cli = request_cli
    expected = {
      "ex " => nil,
      "ex -" => nil,
      "ex edit " => :any,
      "ex edit --into " => :dirs,
      "ex use " => nil,
      "ex use --tool " => nil,
      "ex run " => nil,
      "ex run -- " => :any,
      "ex forward " => :commands,
      "ex forward git " => :any
    }

    expected.each do |line, files|
      actual = cli::COMPLETER.answer(line).files
      files ? assert_equal(files, actual, line) : assert_nil(actual, line)
    end
  end

  def test_flags_do_not_close_a_bare_position_to_paths
    cli = generate(<<~KDL, "RequestFlagFallback")
      name "ex"
      bin "ex"
      flag "--verbose"
      arg "[INPUT]"
    KDL

    bare = cli::COMPLETER.answer("ex ")
    assert_empty bare.candidates
    assert_equal :any, bare.files

    dashed = cli::COMPLETER.answer("ex -")
    refute_empty dashed.candidates
    assert_nil dashed.files
  end

  def test_open_ended_types_suppress_path_fallback
    %w[none username hostname url email].each do |type|
      cli = generate(<<~KDL, "RequestType#{type.capitalize}")
        name "ex"
        bin "ex"
        complete "URL" type="#{type}"
        arg "[URL]"
      KDL

      assert_nil cli::COMPLETER.answer("ex ").files, type
    end

    cli = generate(<<~KDL, "RequestTypeUnknown")
      name "ex"
      bin "ex"
      complete "URL" type="unknown"
      arg "[URL]"
    KDL
    assert_equal :any, cli::COMPLETER.answer("ex ").files
  end

  def test_hidden_choices_close_path_fallback
    cli = generate(<<~KDL, "RequestHiddenChoices")
      name "ex"
      bin "ex"
      arg "[MODE]" {
        choices {
          choice "hidden" hide=#true
        }
      }
    KDL

    answer = cli::COMPLETER.answer("ex h")
    assert_empty answer.candidates
    assert_nil answer.files
  end

  def test_collecting_flag_owns_the_position_before_a_separator_argument
    cli = generate(<<~KDL, "RequestCollectingFlag")
      name "ex"
      bin "ex"
      complete "PATH" type="path"
      flag "--tools <PATH>..."
      arg "[TASK]" double_dash=required
    KDL

    assert_equal :any, cli::COMPLETER.answer("ex --tools a ").files
  end

  def test_huge_cursor_falls_back_to_the_end
    cli = generate("name \"ex\"\nbin \"ex\"\ncmd \"use\" {}\n", "RequestHugeCursor")
    expected = cli.complete(%w[__complete_word__ --line ex\ ])

    %w[18446744073709551616 99999999999999999999].each do |cursor|
      actual = cli.complete(["__complete_word__", "--line", "ex ", "--cursor", cursor])
      assert_equal expected, actual
    end
  end

  private

  def generate(spec, name)
    source, stderr, status = Open3.capture3(USAGE, "generate", "ruby", "--spec", spec, "--module", name)
    raise stderr unless status.success?

    eval(source, TOPLEVEL_BINDING, "#{name}.rb") # standard:disable Security/Eval
    Object.const_get(name)
  end

  def request_cli
    @request_cli ||= generate(<<~KDL, "RequestFixture")
      name "ex"
      bin "ex"
      complete "COMMAND" type="command_args"
      cmd "edit" {
        flag "--into <DIR>"
        arg "[FILE]"
      }
      cmd "use" {
        flag "--tool <TOOL>" {
          choices "node" "python"
        }
        arg "[TOOL]" {
          choices "node" "python"
        }
      }
      cmd "run" {
        arg "[TASK]" double_dash=required
      }
      cmd "forward" {
        arg "[COMMAND]..." double_dash=automatic
      }
    KDL
  end
end
