require "json"
require "open3"
require_relative "test_helper"

class MiseTest < Minitest::Test
  GENERATED = :GeneratedMiseParity
  REPO = File.expand_path("../../..", __dir__)
  SPEC = File.join(REPO, "benches/mise.usage.kdl")
  USAGE = ENV.fetch("USAGE_BIN", File.join(REPO, "target/debug/usage"))
  XTASK = ENV.fetch("XTASK_BIN", File.join(REPO, "target/debug/xtask"))

  def test_generated_default_fills
    parsed = parse(%w[bootstrap packages import])
    key = flag("manager", %w[bootstrap packages import]).key

    assert_equal ["brew"], parsed.values.fetch(key)
    assert_equal :default, parsed.sources.fetch(key)
  end

  def test_generated_choices_are_enforced
    parse(%w[--log-level debug])
    error = assert_raises(Usage::Error) { parse(%w[--log-level chatty]) }

    assert_includes error.message, "invalid value for log-level"
  end

  def test_command_line_beats_generated_default
    parsed = parse(%w[bootstrap packages import --manager brew])
    key = flag("manager", %w[bootstrap packages import]).key

    assert_equal ["brew"], parsed.values.fetch(key)
    assert_equal :argv, parsed.sources.fetch(key)
  end

  def test_every_entry_has_matching_metadata
    checked = 0
    each_command do |cmd|
      assert_nil mise::META[cmd.key], "command #{cmd.name.inspect} has metadata"
      [*cmd.flags, *cmd.args, *cmd.clause&.args].compact.each do |entry|
        meta = mise::META[entry.key]
        refute_nil meta, "#{entry.name.inspect} of #{cmd.name.inspect} has no metadata"
        assert_equal entry.name, meta[:name]
        assert_equal entry.is_a?(Usage::Flag), meta.fetch(:flag, false)
        checked += 1
      end
    end

    assert_operator checked, :>, 800
  end

  def test_relationships_point_at_real_entries
    mise::META.entries.compact.each do |meta|
      %i[conflicts overrides required_unless].flat_map { meta.fetch(_1, []) }.each do |key|
        refute_nil mise::META[key], "#{meta[:name].inspect} points at missing key #{key}"
      end
    end
  end

  def test_typed_boolean_counts_as_given
    key = flag("quiet").key
    typed = parse(%w[--quiet])
    absent = parse(%w[config ls])

    assert_equal :argv, typed.sources.fetch(key)
    refute absent.sources.key?(key)
  end

  def test_generated_help_pages_match_the_reference
    reference = reference_pages
    differences = []
    checked = 0

    each_command do |cmd, path|
      key = path.drop(1).join(" ")
      expected = reference[key]
      unless expected
        differences << "#{key.inspect}: no reference page"
        next
      end
      page = mise::HELP.entries.fetch(cmd.key)
      differences << "#{key.inspect}: short page differs" unless page.short == expected.fetch("short")
      differences << "#{key.inspect}: long page differs" unless page.long == expected.fetch("long")
      checked += 1
    end

    assert_operator checked, :>, 200
    assert_empty differences, differences.first(4).join("\n")
  end

  def test_generated_page_reads_as_a_page
    page = mise::HELP.fetch(command(%w[config ls]).key, long: false)

    [
      "List config files currently in use",
      "Usage: mise config ls [FLAGS]",
      "Flags:",
      "-J, --json",
      "-h, --help",
      "Global flags:",
      "-C, --cd <DIR>"
    ].each { assert_includes page, _1 }
  end

  def test_generated_parse_fills_structs
    cli = mise.parse(%w[use -g node@20])

    assert cli.use.global
    assert_equal ["node@20"], cli.use.tool_version
    assert_nil cli.config
  end

  def test_generated_parse_keeps_automatic_trailing_args_together
    run = mise.parse(%w[tasks run build extra -- --verbose]).tasks.run

    assert_equal "build", run.task
    assert_equal %w[extra -- --verbose], run.args
    assert_empty run.args_last
  end

  def test_generated_parse_applies_a_default
    result = mise.parse(%w[bootstrap packages import])

    assert_equal "brew", result.bootstrap.packages.import.manager
  end

  def test_generated_parse_enforces_choices
    error = assert_raises(Usage::Error) { mise.parse(%w[--log-level chatty]) }

    assert_includes error.message, "invalid value for log-level"
  end

  def test_real_command_lines
    use = parse(%w[use -g node@20])
    assert_equal [mise::ROOT.key, command(["use"]).key], use.cmd_keys
    assert use.boolean(flag("global", ["use"]).key)
    assert_equal ["node@20"], use.values.fetch(arg("TOOL@VERSION", ["use"]).key)

    run = parse(%w[tasks run build extra --dry-run -- --verbose])
    assert_equal ["build"], run.values.fetch(arg("TASK", %w[tasks run]).key)
    assert_equal %w[extra --dry-run -- --verbose], run.values.fetch(arg("ARGS", %w[tasks run]).key)

    exec = parse(%w[x node@20 -- node -v])
    assert_equal command(["exec"]).key, exec.cmd_keys.last
    assert_equal ["node@20"], exec.values.fetch(arg("TOOL@VERSION", ["exec"]).key)
    assert_equal %w[node -v], exec.values.fetch(arg("COMMAND", ["exec"]).key)

    config = parse(%w[config ls --no-header])
    assert config.boolean(flag("no-header", %w[config ls]).key)

    nested_global = parse(%w[config ls --cd /tmp])
    assert_equal ["/tmp"], nested_global.values.fetch(flag("cd").key)

    assert_equal ["--wat"], parse(%w[use --wat]).values.fetch(arg("TOOL@VERSION", ["use"]).key)
    assert_raises(Usage::Error) { parse(%w[run --wat]) }
  end

  def test_default_subcommand_is_the_roots_own_run
    root_run = mise::ROOT.cmds.find { _1.name == "run" }

    assert_same root_run, mise::ROOT.default_cmd
    refute_same command(%w[oci run]), mise::ROOT.default_cmd
  end

  def test_keys_are_unique_and_dense
    keys = []
    each_command do |cmd|
      keys << cmd.key
      keys.concat(cmd.flags.map(&:key), cmd.args.map(&:key))
      keys.concat(cmd.clause.args.map(&:key)) if cmd.clause
    end

    assert_operator keys.length, :>, 900
    assert_equal keys.length, keys.uniq.length
    assert_equal (1..keys.length).to_a, keys.sort
  end

  private

  def arg(name, path = [])
    command(path).args.find { _1.name == name }
  end

  def command(path)
    path.reduce(mise::ROOT) { |cmd, name| cmd.cmds.find { _1.name == name } }
  end

  def each_command(cmd = mise::ROOT, path = ["mise"], &block)
    yield cmd, path
    cmd.cmds.each { each_command(_1, [*path, _1.name], &block) }
  end

  def flag(name, path = [])
    command(path).flags.find { _1.name == name }
  end

  def mise
    return Object.const_get(GENERATED) if Object.const_defined?(GENERATED, false)

    source, stderr, status = Open3.capture3(USAGE, "generate", "ruby", "-f", SPEC, "--module", GENERATED.to_s)
    raise stderr unless status.success?

    eval(source, TOPLEVEL_BINDING, "#{GENERATED}.rb") # standard:disable Security/Eval
    Object.const_get(GENERATED)
  end

  def parse(args)
    Usage::Parser.new(mise::ROOT, mise::META, args, env: {}).parse
  end

  def reference_pages
    stdout, stderr, status = Open3.capture3(XTASK, "help-pages", SPEC)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end
end
