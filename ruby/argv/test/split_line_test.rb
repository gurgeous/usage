require_relative "test_helper"

class SplitLineTest < Minitest::Test
  def test_splitting
    {
      "ex inst⌶" => [%w[ex inst], 1, "inst"],
      "ex ⌶" => [["ex", ""], 1, ""],
      "ex ins⌶tall" => [%w[ex install], 1, "ins"],
      "ex ⌶install" => [["ex", "", "install"], 1, ""],
      'ex "two words⌶' => [["ex", "two words"], 1, "two words"],
      'ex "" ⌶' => [["ex", "", ""], 2, ""],
      "" => [[""], 0, ""]
    }.each do |line, expected|
      split = split_at(line)
      assert_equal expected, [split.words, split.cword, split.prefix], line
    end
  end

  def test_shell_quoting
    assert_equal "C:\\Users\\me", split_at('ex "C:\\Users\\me⌶').prefix
    assert_equal 'say "hi"', split_at('ex "say \\"hi\\"⌶').prefix
    assert_equal "C:\\Users\\me", split_at("ex C:\\Users\\me⌶", :powershell).prefix
    assert_equal "it's", split_at("ex 'it''s'⌶", :powershell).prefix
    assert_equal "its", split_at("ex 'it''s'⌶").prefix
  end

  def test_argv_excludes_program_and_partial
    assert_equal ["install"], split_at("ex install no⌶").argv
    assert_empty split_at("ex ⌶").argv
  end

  private

  def split_at(line, shell = :bash)
    cursor = line.index("⌶") || line.bytesize
    Usage::SplitLine.new(line.sub("⌶", ""), cursor: cursor, shell: shell)
  end
end
