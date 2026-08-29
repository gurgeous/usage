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

  private

  def generate(spec, name)
    source, stderr, status = Open3.capture3(USAGE, "generate", "ruby", "--spec", spec, "--module", name)
    raise stderr unless status.success?

    eval(source, TOPLEVEL_BINDING, "#{name}.rb") # standard:disable Security/Eval
    Object.const_get(name)
  end
end
