require_relative "test_helper"

class TablesTest < Minitest::Test
  def test_default_arrays_are_not_shared
    first = Usage::Command.new(key: 1, name: "first")
    second = Usage::Command.new(key: 2, name: "second")

    refute_same first.flags, second.flags
  end
end
