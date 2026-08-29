require_relative "test_helper"

class TablesTest < Minitest::Test
  def test_default_arrays_are_not_shared
    first = Usage::Command.new(key: 1, name: "first")
    second = Usage::Command.new(key: 2, name: "second")

    refute_same first.flags, second.flags
  end

  def test_help_pages_render_short_long_and_recursive_help
    pages = Usage::HelpPages.new(
      {
        1 => Usage::HelpPage.new(children: [3, 2], long: "root long\n", short: "root short\n"),
        2 => Usage::HelpPage.new(children: [], long: "second long\n", short: "second short\n"),
        3 => Usage::HelpPage.new(children: [], long: "first long\n", short: "first short\n")
      }
    )

    short = Usage::Help.new("help requested").tap { _1.all, _1.cmd_key, _1.long = false, 1, false }
    all = Usage::Help.new("help requested").tap { _1.all, _1.cmd_key, _1.long = true, 1, true }

    assert_equal "root short\n", pages.render(short)
    assert_equal "root long\n\nfirst long\n\nsecond long\n", pages.render(all)
  end
end
