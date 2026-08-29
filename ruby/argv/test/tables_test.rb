require_relative "test_helper"

class TablesTest < Minitest::Test
  def test_default_arrays_are_not_shared
    first = Usage::Command.new(key: 1, name: "first")
    second = Usage::Command.new(key: 2, name: "second")

    refute_same first.flags, second.flags
  end

  def test_help_pages_render_short_long_and_recursive_help
    first = Usage::Command.new(key: 3, name: "first")
    second = Usage::Command.new(key: 2, name: "second")
    root = Usage::Command.new(key: 1, name: "ex", cmds: [second, first])
    spec = Usage::HelpSpec.new(bin: "ex", name: "ex", about: "root help")
    meta = Usage::HelpMetadata.new([
      {key: 1},
      {key: 2, short: "second help"},
      {key: 3, short: "first help", display_order: 1, display_order_set: true}
    ])
    pages = Usage::HelpPages.new(root, spec, meta)

    short = Usage::Help.new("help requested").tap { _1.all, _1.cmd_key, _1.long = false, 1, false }
    all = Usage::Help.new("help requested").tap { _1.all, _1.cmd_key, _1.long = true, 1, true }

    assert_includes pages.render(short), "root help"
    rendered = pages.render(all)
    assert_operator rendered.index("Usage: ex first"), :<, rendered.index("Usage: ex second")
  end

  def test_metadata_lookup_requires_a_dense_matching_key
    [Usage::Metadata, Usage::CompletionMetadata, Usage::HelpMetadata].each do |type|
      table = type.new([{key: 1, name: "a"}, {key: 2, name: "b"}, {key: 3, name: "c"}])
      assert_equal "b", table[2][:name]
      assert_nil table[0]
      assert_nil table[4]
      assert_nil table[1 << 40]
      assert_nil type.new([{key: 7, name: "wrong"}])[1]
    end
  end
end
