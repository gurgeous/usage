require_relative "test_helper"

class HelpPagesTest < Minitest::Test
  def test_terminal_width_matches_the_rust_adapter
    renderer = pages(command(1), [{key: 1}])
    previous = ENV["COLUMNS"]
    ENV["COLUMNS"] = "120"

    assert_equal 120, renderer.send(:terminal_width, nil)
    assert_equal 70, renderer.send(:terminal_width, {max_term_width: 70})
    assert_equal 120, renderer.send(:terminal_width, {max_term_width: 0})
    assert_equal 40, renderer.send(:terminal_width, {term_width: 40, max_term_width: 20})
    assert_predicate renderer.send(:terminal_width, {term_width: 0}), :infinite?

    ENV["COLUMNS"] = "invalid"
    assert_equal 80, renderer.send(:terminal_width, nil)
    ENV["COLUMNS"] = "-1"
    assert_equal 80, renderer.send(:terminal_width, nil)
  ensure
    ENV["COLUMNS"] = previous
  end

  def test_long_only_command_help_stays_off_the_short_listing
    run = command(2, "run")
    renderer = pages(command(1, cmds: [run]), [
      {key: 1}, {key: 2, long: "Only on the long page."}
    ])

    short = renderer.fetch(2, long: false)
    long = renderer.fetch(2, long: true)
    refute_includes short, "Only on the long page."
    assert_includes long, "Only on the long page."
    assert_includes renderer.fetch(1, long: false), "Only on the long page."
  end

  def test_short_after_help_has_one_blank_line
    renderer = pages(command(1), [{key: 1}], after_help: "Read more.")
    page = renderer.fetch(1, long: false)

    assert_includes page, "Print help\n\nRead more."
    refute_includes page, "\n\n\n"
  end

  def test_empty_program_name_keeps_subcommand_paths
    run = command(2, "run")
    spec = Usage::HelpSpec.new(name: "", bin: "")
    renderer = Usage::HelpPages.new(
      command(1, "", cmds: [run]), spec,
      Usage::HelpMetadata.new([{key: 1}, {key: 2, short: "Run it"}])
    )

    assert_includes renderer.fetch(1, long: false), "Usage:  <SUBCOMMAND>"
    assert_includes renderer.fetch(2, long: false), "Usage: run"
  end

  def test_nested_lists_keep_their_hanging_indent
    renderer = pages(command(1), [{key: 1}])

    assert_equal ["  - a nested item with", "    enough words to wrap"],
      renderer.send(:wrap, "  - a nested item with enough words to wrap", 24)
    assert_equal ["  1. a numbered item", "     with enough words", "     to wrap"],
      renderer.send(:wrap, "  1. a numbered item with enough words to wrap", 24)
  end

  def test_examples_fall_back_to_the_root
    sub = command(2, "run")
    root = command(1, cmds: [sub])
    renderer = pages(root, [
      {key: 1, examples: [{header: "Build it", code: "ex build"}]},
      {key: 2, short: "run it"}
    ])

    assert_includes renderer.fetch(2, long: false), "$ ex build"
    assert_includes renderer.fetch(2, long: true), "$ ex build"
    renderer.entries.entries[1][:examples] = [{code: "ex run --now"}]
    own = renderer.fetch(2, long: false)
    assert_includes own, "ex run --now"
    refute_includes own, "ex build"
  end

  def test_long_help_ends_with_authorship_and_license
    renderer = pages(command(1), [{key: 1}], author: "A. Person", license: "MIT")

    assert renderer.fetch(1, long: true).end_with?("Author: A. Person\nLicense: MIT\n")
    refute_includes renderer.fetch(1, long: false), "Author:"
  end

  def test_hidden_flag_aliases_stay_out_of_help
    flag = Usage::Flag.new(
      key: 2, name: "output", longs: %w[output quietly], hidden_longs: ["quietly"],
      shorts: %w[o q], hidden_shorts: ["q"]
    )
    rendered = pages(command(1, flags: [flag]), [{key: 1}, {key: 2, short: "write output"}]).fetch(1, long: true)

    %w[--output -o].each { assert_includes rendered, _1 }
    %w[--quietly -q].each { refute_includes rendered, _1 }
  end

  def test_repeatable_flag_uses_ordinary_spelling
    flag = Usage::Flag.new(
      key: 2, name: "allow", longs: ["allow"], shorts: ["A"],
      takes_value: true
    )
    renderer = pages(command(1, flags: [flag]), [
      {key: 1}, {key: 2, repeatable: true, value_name: "NAME", value_demanded: true}
    ])

    [false, true].each do |long|
      page = renderer.fetch(1, long:)
      assert_includes page, "-A, --allow <NAME>"
      refute_includes page, "--allow…"
    end
  end

  def test_fixed_arity_help_keeps_distinct_value_names
    flag = Usage::Flag.new(key: 2, name: "range", longs: ["range"], takes_value: true, variadic: true)
    arg = Usage::Argument.new(key: 3, name: "PAIR", variadic: true)
    root = command(1, flags: [flag], args: [arg])
    rendered = pages(root, [
      {key: 1},
      {key: 2, value_demanded: true, value_names: %w[START END]},
      {key: 3, demanded: true, value_names: %w[LEFT RIGHT]}
    ]).fetch(1, long: false)

    assert_includes rendered, "--range <START> <END>"
    assert_includes rendered, "<LEFT> <RIGHT>"
  end

  def test_fixed_arity_help_repeats_one_value_name
    flag = Usage::Flag.new(key: 2, name: "pair", longs: ["pair"], takes_value: true, variadic: true)
    arg = Usage::Argument.new(key: 3, name: "ITEM", variadic: true)
    rendered = pages(command(1, flags: [flag], args: [arg]), [
      {key: 1},
      {key: 2, value_name: "ITEM", value_arity: 2, value_demanded: true},
      {key: 3, value_arity: 2, demanded: true}
    ]).fetch(1, long: false)

    assert_includes rendered, "--pair <ITEM> <ITEM>"
    assert_includes rendered, "<ITEM> <ITEM>"
    refute_includes rendered, "<ITEM>…"
  end

  def test_granular_help_hides
    flags = [
      Usage::Flag.new(key: 2, name: "mode", longs: ["mode"], takes_value: true),
      Usage::Flag.new(key: 3, name: "short-only", longs: ["short-only"]),
      Usage::Flag.new(key: 4, name: "long-only", longs: ["long-only"])
    ]
    renderer = pages(command(1, flags:), [
      {key: 1},
      {key: 2, short: "mode", choices: %w[fast slow], env: "MODE", default: ["fast"],
       hide_possible_values: true, hide_env: true, hide_default_value: true},
      {key: 3, short: "short", hide_long_help: true},
      {key: 4, short: "long", hide_short_help: true}
    ])
    short, long = [false, true].map { renderer.fetch(1, long: _1) }

    assert_includes short, "--short-only"
    refute_includes short, "--long-only"
    assert_includes long, "--long-only"
    refute_includes long, "--short-only"
    [short, long].each do |page|
      ["fast, slow", "MODE", "default: fast"].each { refute_includes page, _1 }
    end
  end

  def test_subcommand_presentation
    sub = command(2, "run")
    renderer = pages(command(1, cmds: [sub]), [
      {key: 1, subcommand_help_heading: "Actions", subcommand_value_name: "ACTION"},
      {key: 2, short: "run it"}
    ])

    [false, true].each do |long|
      page = renderer.fetch(1, long:)
      assert_includes page, "Usage: ex <ACTION>"
      assert_includes page, "\nActions:\n"
    end
  end

  def test_command_deprecation_appears_in_listings_and_flattened_help
    old = command(2, "old")
    root = command(1, cmds: [old])
    metadata = [{key: 1}, {key: 2, short: "old command", deprecated_warn_at: "6.1"}]
    renderer = pages(root, metadata)

    [false, true].each { assert_includes renderer.fetch(1, long: _1), "[deprecated: warns at 6.1]" }
    metadata[0][:flatten_help] = true
    assert_includes renderer.fetch(1, long: false), "old command\n[deprecated: warns at 6.1]"
  end

  def test_subcommand_help_headings
    cmds = [command(2, "run"), command(3, "clean"), command(4, "status")]
    renderer = pages(command(1, cmds:), [
      {key: 1},
      {key: 2, short: "run it", heading: "Core commands"},
      {key: 3, short: "remove state", heading: "Maintenance"},
      {key: 4, short: "show status", heading: "Commands"}
    ])

    [false, true].each do |long|
      page = renderer.fetch(1, long:)
      commands = page.index("\nCommands:\n")
      assert_operator page.index("\nCore commands:\n"), :>, commands
      assert_operator page.index("\nMaintenance:\n"), :>, commands
      assert_equal 1, page.scan("\nCommands:\n").length
    end
  end

  def test_explicit_display_order
    flags = [
      Usage::Flag.new(key: 2, name: "second", longs: ["second"]),
      Usage::Flag.new(key: 3, name: "first", longs: ["first"])
    ]
    cmds = [command(4, "second"), command(5, "first")]
    renderer = pages(command(1, flags:, cmds:), [
      {key: 1},
      {key: 2, short: "shown second", display_order: 20, display_order_set: true},
      {key: 3, short: "shown first", display_order: 10, display_order_set: true},
      {key: 4, short: "shown second", display_order: 20, display_order_set: true},
      {key: 5, short: "shown first", display_order: 10, display_order_set: true}
    ])

    [false, true].each do |long|
      page = renderer.fetch(1, long:)
      commands = page.split("\nCommands:\n", 2).last
      flags = page.split("\nFlags:\n", 2).last
      assert_operator commands.index("first"), :<, commands.index("second")
      assert_operator flags.index("--first"), :<, flags.index("--second")
    end
  end

  def test_next_line_help
    arg = Usage::Argument.new(key: 2, name: "input", required: true)
    flags = [
      Usage::Flag.new(key: 3, name: "verbose", longs: ["verbose"]),
      Usage::Flag.new(key: 5, name: "mode", longs: ["mode"])
    ]
    sub = command(4, "run")
    renderer = pages(command(1, args: [arg], flags:, cmds: [sub]), [
      {key: 1, next_line_help: true},
      {key: 2, short: "Input file"},
      {key: 3, short: "Enable verbose output", deprecated: "use --log-level"},
      {key: 4, short: "Run it\n"},
      {key: 5, env: "MODE", default: ["fast"], choices: %w[fast slow]}
    ])

    [false, true].each do |long|
      page = renderer.fetch(1, long:)
      assert_includes page, "  [input]\n    Input file"
      assert_includes page, "  --verbose\n    Enable verbose output"
      assert_includes page, "  run\n    Run it"
      assert_equal 1, page.scan("[deprecated: use --log-level]").length
    end
  end

  def test_flatten_help
    arg = Usage::Argument.new(key: 3, name: "task", required: true)
    long_flag = Usage::Flag.new(key: 4, name: "extraordinarily-long-flag", longs: ["extraordinarily-long-flag"])
    deep = Usage::Flag.new(key: 6, name: "deep", longs: ["deep"])
    nested = command(5, "nested", flags: [deep])
    run = command(2, "run", args: [arg], flags: [long_flag], cmds: [nested])
    renderer = pages(command(1, cmds: [run]), [
      {key: 1, flatten_help: true},
      {key: 2, short: "Run it", flatten_help: true, next_line_help: true},
      {key: 3, short: "Task name", demanded: true},
      {key: 4, short: "Only show changes", deprecated: "use --mode"},
      {key: 5, short: "Nested operation"},
      {key: 6, short: "Deep option"}
    ])

    [false, true].each do |long|
      page = renderer.fetch(1, long:)
      assert_includes page, "Usage: ex\n       ex run"
      assert_includes page, "\nrun:\nRun it"
      assert_includes page, "\nrun nested:\nNested operation"
      refute_includes page, "\nCommands:\n"
    end
  end

  def test_flattened_next_line_help_keeps_deprecation_separate
    flag = Usage::Flag.new(key: 3, name: "old", longs: ["old"])
    run = command(2, "run", flags: [flag])
    renderer = pages(command(1, cmds: [run]), [
      {key: 1, flatten_help: true, next_line_help: true},
      {key: 2, short: "Run it"},
      {key: 3, short: "Old mode", deprecated: "use --new"}
    ])

    assert_includes renderer.fetch(1, long: false), "--old\n    Old mode\n    [deprecated: use --new]"
  end

  def test_a_long_flag_only_moves_its_own_help_below
    flags = [
      Usage::Flag.new(key: 2, name: "short", longs: ["short"]),
      Usage::Flag.new(
        key: 3, name: "this-flag-name-is-far-beyond-the-column-cap",
        longs: ["this-flag-name-is-far-beyond-the-column-cap"]
      )
    ]
    renderer = pages(command(1, flags:), [
      {key: 1}, {key: 2, short: "ordinary help"}, {key: 3, short: "alpha beta"}
    ])

    [false, true].each do |long|
      page = renderer.fetch(1, long:)
      assert_includes page, "      --short                     ordinary help"
      assert_match(/--this-flag-name-is-far-beyond-the-column-cap\n +alpha beta/, page)
    end
  end

  def test_description_ending_in_a_break_adds_no_blank_line
    run = command(2, "run")
    renderer = pages(command(1, cmds: [run]), [
      {key: 1}, {key: 2, short: "run it\n", long: "run it\n\nExamples:\n\n    $ ex run\n"}
    ])

    assert_includes renderer.fetch(2, long: true), "$ ex run\n\nUsage:"
    refute_includes renderer.fetch(2, long: true), "$ ex run\n\n\nUsage:"
    refute_includes renderer.fetch(1, long: false), "run it\n\n  help"
  end

  def test_all_help_walks_visible_descendants
    leaf = command(3, "leaf")
    hidden = command(4, "hidden")
    parent = command(2, "parent", cmds: [hidden, leaf])
    early = command(5, "early")
    zulu = command(6, "zulu")
    renderer = pages(command(1, cmds: [zulu, parent, early]), [
      {key: 1}, {key: 2, short: "parent"}, {key: 3, short: "leaf"},
      {key: 4, hide: true}, {key: 5, display_order: 1, display_order_set: true}, {key: 6}
    ])
    page = renderer.all_pages(["ex"], [renderer.root])

    ["ex", "ex early", "ex parent", "ex parent leaf", "ex zulu"].each do |path|
      assert_includes page, "Usage: #{path}"
    end
    refute_includes page, "Usage: ex parent hidden"
    assert_operator page.index("Usage: ex early"), :<, page.index("Usage: ex parent")
  end

  def test_heading_prose
    flags = [
      Usage::Flag.new(key: 2, name: "allow", longs: ["allow"], shorts: ["A"]),
      Usage::Flag.new(key: 3, name: "quiet", longs: ["quiet"])
    ]
    renderer = pages(command(1, flags:), [
      {key: 1, headings: [
        {title: "Filters", help: "Filters accumulate from left to right.\nFor example: `-A no-debugger`."},
        {title: "Flags", help: "Should not appear"}
      ]},
      {key: 2, short: "allow a rule", heading: "Filters"},
      {key: 3, short: "say less"}
    ])

    long = renderer.fetch(1, long: true)
    assert_includes long, "\nFilters:\n  Filters accumulate from left to right."
    refute_includes long, "Should not appear"
    refute_includes renderer.fetch(1, long: false), "accumulate from left to right"
  end

  def test_subcommand_heading_prose
    compile = command(2, "compile")
    renderer = pages(command(1, cmds: [compile]), [
      {key: 1, headings: [{title: "Build Commands", help: "These write to the target directory."}]},
      {key: 2, short: "compile it", heading: "Build Commands"}
    ])

    assert_includes renderer.fetch(1, long: true), "\nBuild Commands:\n  These write to the target directory.\n\n"
    refute_includes renderer.fetch(1, long: false), "These write to"
  end

  def test_template_reorders_omits_and_strips_styles
    flag = Usage::Flag.new(key: 2, name: "verbose", longs: ["verbose"])
    renderer = pages(
      command(1, flags: [flag]), [{key: 1}, {key: 2, short: "say more"}],
      about: "about", help_template: "{$heading}OPTIONS{/$}\n{{flags}}\n\n{{about}}"
    )
    page = renderer.fetch(1, long: false)

    assert page.start_with?("OPTIONS\nFlags:")
    assert page.end_with?("about\n")
    refute_includes page, "Usage:"
    refute_includes page, "{$heading}"
  end

  def test_help_style_vocabulary_matches_the_shared_corpus
    canonical = File.read(File.expand_path("../../../corpus/help-template-styles.txt", __dir__)).split

    assert_equal canonical, Usage::HelpPages::Sections::STYLES
  end

  def test_template_reorders_sections_exactly
    force = Usage::Flag.new(key: 2, name: "force", longs: ["force"])
    file = Usage::Argument.new(key: 3, name: "file", required: true)
    renderer = pages(
      command(1, flags: [force], args: [file]),
      [{key: 1}, {key: 2, short: "Do it anyway"}, {key: 3, short: "Which file", demanded: true}],
      about: "An example", help_template: "{{about}}\n\n{{usage}}\n\n{{flags}}\n\n{{args}}"
    )
    expected = <<~HELP
      An example

      Usage: ex [--force] <file>

      Flags:
            --force  Do it anyway
        -h, --help   Print help

      Arguments:
        <file>  Which file
    HELP

    assert_equal expected, renderer.fetch(1, long: false)
  end

  def test_grouped_and_ungrouped_sections_can_be_interleaved
    flags = [
      Usage::Flag.new(key: 2, name: "config", longs: ["config"], takes_value: true),
      Usage::Flag.new(key: 3, name: "verbose", longs: ["verbose"])
    ]
    args = [Usage::Argument.new(key: 4, name: "file"), Usage::Argument.new(key: 5, name: "mode")]
    renderer = pages(
      command(1, flags:, args:),
      [
        {key: 1},
        {key: 2, short: "settings", heading: "Configuration", value_name: "path", value_demanded: true},
        {key: 3, short: "detail"},
        {key: 4, short: "file", demanded: true},
        {key: 5, short: "mode", heading: "Modes"}
      ],
      help_template: "{{grouped_flags}}\n\n{{ungrouped_args}}\n\n{{ungrouped_flags}}\n\n{{grouped_args}}"
    )
    page = renderer.fetch(1, long: false)
    positions = ["Configuration:", "Arguments:", "Flags:", "Modes:"].map { page.index(_1) }

    assert_equal positions.sort, positions
    %w[--config <file> --verbose --help [mode]].each { assert_includes page, _1 }
  end

  def test_template_closes_gaps_left_by_missing_sections
    force = Usage::Flag.new(key: 2, name: "force", longs: ["force"])
    renderer = pages(
      command(1, flags: [force]), [{key: 1}, {key: 2, short: "Do it anyway"}],
      about: "An example",
      help_template: "{{about}}\n\n{{usage}}\n\n{{commands}}\n\n{{args}}\n\n{{flags}}\n\n{{after_help}}"
    )

    refute_includes renderer.fetch(1, long: false), "\n\n\n"
  end

  def test_template_omits_a_section
    install = command(2, "install")
    renderer = pages(
      command(1, cmds: [install]), [{key: 1}, {key: 2, short: "Install a tool"}],
      about: "An example", help_template: "{{about}}\n\n{{usage}}\n\n{{flags}}"
    )
    page = renderer.fetch(1, long: false)

    refute_includes page, "Commands:"
    assert_includes page, "Flags:"
  end

  def test_template_wraps_sections_in_text
    force = Usage::Flag.new(key: 2, name: "force", longs: ["force"])
    renderer = pages(
      command(1, flags: [force]), [{key: 1}, {key: 2, short: "Do it anyway"}],
      help_template: "== ex ==\n\n{{usage}}\n\n{{flags}}\n\nSee https://example.com/docs for more."
    )
    page = renderer.fetch(1, long: false)

    assert page.start_with?("== ex ==\n\nUsage:")
    assert page.end_with?("See https://example.com/docs for more.\n")
  end

  def test_template_gathers_long_page_trailing_sections
    force = Usage::Flag.new(key: 2, name: "force", longs: ["force"])
    root = command(1, flags: [force], version: true)
    renderer = pages(
      root,
      [{key: 1, examples: [{header: "Force it", code: "ex --force"}]}, {key: 2, short: "Do it anyway"}],
      about: "An example", version: "1.2.3", author: "Ex Ample", after_help: "Read the docs.",
      help_template: "{{after_help}}\n\n{{usage}}\n\n{{flags}}\n\n{{about}}"
    )
    page = renderer.fetch(1, long: true)

    assert page.start_with?("Examples:\n  Force it:\n    $ ex --force")
    assert_operator page.index("Author: Ex Ample"), :<, page.index("Usage: ex")
    assert page.end_with?("ex 1.2.3\nAn example\n")
  end

  def test_template_styles_span_lines_and_empty_sections
    renderer = pages(
      command(1), [{key: 1}],
      help_template: "{$heading}\nCUSTOM HELP\n{/$}\n\n{$dim}\n{{args}}\n{/$}\n\n{{usage}}\n\n{$$heading} is literal"
    )

    assert_equal "CUSTOM HELP\n\nUsage: ex\n\n{$heading} is literal\n", renderer.fetch(1, long: false)
  end

  def test_page_without_a_template_is_unchanged
    renderer = pages(command(1), [{key: 1}])
    expected = renderer.fetch(1, long: false)

    ["", "  ", "\n\t"].each do |template|
      renderer.spec.help_template = template
      assert_equal expected, renderer.fetch(1, long: false)
    end
  end

  def test_clause_arguments_appear_in_usage_and_help
    task = Usage::Argument.new(key: 2, name: "task", required: true)
    args = Usage::Argument.new(key: 3, name: "args", variadic: true)
    clause = Usage::Clause.new(key: 4, name: "tasks", sep: ":::", args: [task, args])
    renderer = pages(command(1, clause:), [
      {key: 1}, {key: 2, short: "Task to run", demanded: true}, {key: 3, short: "Arguments for the task"}, nil
    ])
    page = renderer.fetch(1, long: false)

    assert_includes page, "Usage: ex <task> [args]… [::: <task> [args]…]…"
    %w[Arguments: <task> [args]…].each { assert_includes page, _1 }
  end

  def test_unknown_placeholders_and_malformed_styles_stay_literal
    renderer = pages(command(1), [{key: 1}], help_template: "before {$red and {{usage}}\n\n{{options}}")
    page = renderer.fetch(1, long: false)

    assert_includes page, "before {$red and Usage: ex"
    assert_includes page, "{{options}}"
  end

  def test_plain_page_strips_template_colour_markup_only
    renderer = pages(
      command(1), [{key: 1}], about: "Literal {$red} prose",
      help_template: "{$heading}Custom help{/$}\n\n{{about}}\n\n{{usage}}"
    )

    assert renderer.fetch(1, long: false).start_with?("Custom help\n\nLiteral {$red} prose\n\nUsage: ex")
  end

  def test_plain_page_keeps_escaped_and_malformed_style_markup_literal
    escaped = pages(
      command(1), [{key: 1}], help_template: "{$$heading}literal{/$$}\n\n{{usage}}"
    ).fetch(1, long: false)
    malformed = pages(
      command(1), [{key: 1}], help_template: "before {$red and {{usage}}"
    ).fetch(1, long: false)

    assert_equal "{$heading}literal{/$}\n\nUsage: ex\n", escaped
    assert malformed.start_with?("before {$red and Usage: ex")
  end

  def test_section_vocabulary_matches_the_portable_template
    expected = %i[
      about usage commands args flags grouped_args ungrouped_args grouped_flags
      ungrouped_flags after_help
    ]
    assert_equal expected, Usage::HelpPages::Sections::NAMES

    template = expected.map { "{{#{_1}}}" }.join("\n\n")
    renderer = pages(command(1), [{key: 1}], help_template: template)
    refute_includes renderer.fetch(1, long: false), "{{"
  end

  private

  def command(key, name = "ex", **fields)
    Usage::Command.new(key:, name:, **fields)
  end

  def pages(root, entries, **fields)
    spec = Usage::HelpSpec.new(name: "ex", bin: "ex", **fields)
    Usage::HelpPages.new(root, spec, Usage::HelpMetadata.new(entries))
  end
end
