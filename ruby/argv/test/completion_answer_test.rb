require_relative "test_helper"

class CompletionAnswerTest < Minitest::Test
  def test_shell_formats
    answer = Usage::Complete::Answer.new(
      candidates: [
        Usage::Complete::Candidate.new(description: "Installs a tool", kind: :command, value: "use"),
        Usage::Complete::Candidate.new(description: nil, kind: :flag, value: "--global")
      ],
      files: nil
    )

    assert_equal "use\n--global\n", answer.render(:bash)
    assert_equal "use\tInstalls a tool\tuse\n--global\t\t--global\n", answer.render(:zsh)
    %i[fish nu powershell].each do |shell|
      assert_equal "use\tInstalls a tool\n--global\t\n", answer.render(shell), shell
    end
  end

  def test_files_marker
    candidate = candidate("use")

    assert_equal "use\n\x01files\n", answer(candidate, files: :any).render(:bash)
    assert_equal "use\n\x01dirs\n", answer(candidate, files: :dirs).render(:bash)
    assert_equal "use\n", answer(candidate).render(:bash)
  end

  def test_description_columns_are_all_or_nothing
    described = candidate("use", "Installs a tool")
    bare = candidate("--global")

    assert_equal "use\tInstalls a tool\n--global\t\n", answer(described, bare).render(:fish)
    assert_equal "a\nb\n", answer(candidate("a"), candidate("b")).render(:fish)
  end

  def test_descriptions_are_collapsed_onto_one_line
    %i[fish zsh].each do |shell|
      output = answer(candidate("run", "does  a thing\nand\x01another\x7f")).render(shell)

      assert_equal 1, output.count("\n"), shell
      assert_includes output, "does  a thing and another"
      refute_match(/[\x00-\x1f\x7f]/, output.delete("\t\n"))
    end
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
    %i[fish nu powershell].each do |shell|
      output = answer(candidate("bad\tvalue", "description"), candidate("plain")).render(shell)

      assert_equal "plain\n", output, shell
    end
  end

  def test_unsafe_candidates_are_dropped
    rendered = Usage::Complete::Answer.new(
      candidates: [
        Usage::Complete::Candidate.new(value: "one\ttwo\nthree"),
        Usage::Complete::Candidate.new(value: "\x01files"),
        Usage::Complete::Candidate.new(value: "plain")
      ]
    )

    %i[bash zsh fish nu powershell].each do |shell|
      output = rendered.render(shell)
      assert_equal 1, output.count("\n"), shell
      assert output.start_with?("plain"), shell
    end
  end

  private

  def answer(*candidates, files: nil)
    Usage::Complete::Answer.new(candidates:, files:)
  end

  def candidate(value, description = nil)
    Usage::Complete::Candidate.new(description:, value:)
  end
end
