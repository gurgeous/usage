require_relative "test_helper"

class CompletionAnswerTest < Minitest::Test
  def test_shell_formats
    answer = Usage::CompletionAnswer.new(
      candidates: [
        Usage::CompletionCandidate.new(description: "Installs a tool", kind: :command, value: "use"),
        Usage::CompletionCandidate.new(description: nil, kind: :flag, value: "--global")
      ],
      files: nil
    )

    assert_equal "use\n--global\n", answer.render(:bash)
    assert_equal "use\tInstalls a tool\tuse\n--global\t\t--global\n", answer.render(:zsh)
    assert_equal "use\tInstalls a tool\n--global\t\n", answer.render(:fish)
  end

  def test_files_marker
    answer = Usage::CompletionAnswer.new(candidates: [], files: :dirs)

    assert_equal "\x01dirs\n", answer.render(:bash)
  end

  def test_description_columns_are_all_or_nothing
    described = candidate("use", "Installs a tool")
    bare = candidate("--global")

    assert_equal "use\tInstalls a tool\n--global\t\n", answer(described, bare).render(:fish)
    assert_equal "a\nb\n", answer(candidate("a"), candidate("b")).render(:fish)
  end

  def test_descriptions_are_collapsed_onto_one_line
    output = answer(candidate("run", "does  a thing\nand\x01another\x7f")).render(:zsh)

    assert_equal 1, output.count("\n")
    assert_includes output, "does  a thing and another"
    refute_match(/[\x00-\x1f\x7f]/, output.delete("\t\n"))
  end

  def test_zsh_quotes_insertions
    {
      "use" => "use",
      "a/b-c.d:e@f+g=h%i,j_k" => "a/b-c.d:e@f+g=h%i,j_k",
      "two words" => "'two words'",
      "it's" => %q('it'\''s'),
      "" => "''"
    }.each do |value, quoted|
      assert_equal "#{value}\t\t#{quoted}\n", answer(candidate(value)).render(:zsh)
    end
  end

  def test_dropped_rows_do_not_add_a_description_column
    output = answer(candidate("bad\tvalue", "description"), candidate("plain")).render(:fish)

    assert_equal "plain\n", output
  end

  def test_unsafe_candidates_are_dropped
    answer = Usage::CompletionAnswer.new(
      candidates: [
        Usage::CompletionCandidate.new(value: "bad\tvalue"),
        Usage::CompletionCandidate.new(value: "plain")
      ]
    )

    assert_equal "plain\n", answer.render(:bash)
  end

  private

  def answer(*candidates)
    Usage::CompletionAnswer.new(candidates: candidates)
  end

  def candidate(value, description = nil)
    Usage::CompletionCandidate.new(description: description, value: value)
  end
end
