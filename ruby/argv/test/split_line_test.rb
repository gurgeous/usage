require_relative "test_helper"

class SplitLineTest < Minitest::Test
  def test_splitting
    {
      "ex inst⌶" => [%w[ex inst], 1, "inst"],
      "ex ⌶" => [["ex", ""], 1, ""],
      "ex install ⌶" => [["ex", "install", ""], 2, ""],
      "ex ins⌶tall" => [%w[ex install], 1, "ins"],
      "ex ⌶install" => [["ex", "", "install"], 1, ""],
      'ex "two words⌶' => [["ex", "two words"], 1, "two words"],
      "ex 'two words' ⌶" => [["ex", "two words", ""], 2, ""],
      'ex "" ⌶' => [["ex", "", ""], 2, ""],
      'ex two\ wo⌶' => [["ex", "two wo"], 1, "two wo"],
      'ex two\⌶' => [["ex", "two"], 1, "two"],
      "" => [[""], 0, ""],
      "ex⌶" => [["ex"], 0, "ex"]
    }.each do |line, expected|
      split = split_at(line)
      assert_equal expected, [split.words, split.cword, split.prefix], line
    end
  end

  def test_shell_quoting
    assert_equal "C:\\Users\\me", split_at('ex "C:\\Users\\me⌶').prefix
    assert_equal 'say "hi"', split_at('ex "say \\"hi\\"⌶').prefix
    assert_equal "C:\\Users\\me", split_at("ex C:\\Users\\me⌶", :powershell).prefix
    assert_equal '"quoted', split_at('ex `"quoted⌶', :powershell).prefix
    assert_equal "it's", split_at("ex 'it''s'⌶", :powershell).prefix
    assert_equal "its", split_at("ex 'it''s'⌶").prefix
  end

  def test_cursor_outside_or_inside_a_character
    assert_equal "run", Usage::Complete::Line.new("ex run", cursor: 999).prefix
    assert_equal "", Usage::Complete::Line.new("ex ünïcode", cursor: 4).prefix
    assert_equal "ün", Usage::Complete::Line.new("ex ünïcode", cursor: 7).prefix
  end

  def test_argv_excludes_program_and_partial
    assert_equal ["install"], split_at("ex install no⌶").argv
    assert_empty split_at("ex ⌶").argv
    assert_empty split_at("⌶").argv
  end

  private

  def split_at(line, shell = :bash)
    cursor = line.index("⌶") || line.bytesize
    Usage::Complete::Line.new(line.sub("⌶", ""), cursor:, shell:)
  end
end
