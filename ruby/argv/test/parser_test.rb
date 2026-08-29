require_relative "test_helper"

class ParserTest < Minitest::Test
  def test_flags_arguments_and_subcommands
    force = Usage::Flag.new(key: 3, name: "force", longs: ["force"])
    package = Usage::Argument.new(key: 4, name: "package", required: true)
    install = Usage::Command.new(name: "install", key: 2, flags: [force], args: [package])
    verbose = Usage::Flag.new(key: 5, name: "verbose", shorts: ["v"], global: true)
    root = Usage::Command.new(name: "", key: 1, flags: [verbose], cmds: [install], unknown_flags: :error)
    meta = metadata(nil, nil, {key: 3, name: "force", flag: true, boolean: true},
      {key: 4, name: "package", required: true},
      {key: 5, name: "verbose", flag: true, boolean: true})

    parsed = Usage::Parser.new(root, meta, %w[-v install --force rack]).parse

    assert_equal [1, 2], parsed.cmd_keys
    assert parsed.boolean(3)
    assert parsed.boolean(5)
    assert_equal ["rack"], parsed.values[4]
  end

  def test_env_defaults_choices_and_relationships
    file = Usage::Flag.new(key: 2, name: "file", longs: ["file"], takes_value: true)
    stdin = Usage::Flag.new(key: 3, name: "stdin", longs: ["stdin"])
    root = Usage::Command.new(name: "", key: 1, flags: [file, stdin], unknown_flags: :error)
    meta = metadata(nil,
      {key: 2, name: "file", flag: true, spelling: "--file", env: "FILE", choices: %w[a b], conflicts: [3]},
      {key: 3, name: "stdin", flag: true, spelling: "--stdin", boolean: true})

    error = assert_raises(Usage::Error) do
      Usage::Parser.new(root, meta, ["--stdin"], env: {"FILE" => "a"}).parse
    end
    assert_equal "file cannot be given with stdin", error.message

    error = assert_raises(Usage::Error) do
      Usage::Parser.new(root, meta, [], env: {"FILE" => "x"}).parse
    end
    assert_equal "invalid value for file", error.message
  end

  def test_validation_is_rejected_only_for_a_value
    port = Usage::Argument.new(key: 2, name: "port")
    root = Usage::Command.new(name: "", key: 1, args: [port])
    meta = metadata(nil, {key: 2, name: "port", validate: "int(value) > 0"})

    Usage::Parser.new(root, meta, []).parse
    error = assert_raises(Usage::Error) { Usage::Parser.new(root, meta, ["1"]).parse }
    assert_equal "validation expressions are not supported for port", error.message
  end

  def test_multicall_rewrite
    assert_equal "ls", Usage::Parser.multicall_basename("/usr/bin/ls")
    assert_equal "ls", Usage::Parser.multicall_basename("C:\\busybox\\ls.exe")
    assert_equal "LS", Usage::Parser.multicall_basename("LS.EXE")
    assert_equal %w[ls -l], Usage::Parser.rewrite_multicall("/usr/bin/ls", ["-l"], "busybox", "busybox")
    assert_equal %w[ls -l], Usage::Parser.rewrite_multicall("C:\\bin\\ls.exe", ["-l"], "busybox", "busybox")
    assert_equal ["ls"], Usage::Parser.rewrite_multicall("busybox", ["ls"], "busybox", "busybox")
    assert_equal %w[ls -l], Usage::Parser.rewrite_multicall(
      "/usr/bin/busybox", %w[ls -l], "/opt/bin/busybox.exe", ""
    )
    assert_equal %w[ls -l], Usage::Parser.rewrite_multicall(
      "C:\\tools\\busybox.exe", %w[ls -l], "", "/opt/bin/busybox"
    )
    assert_equal ["ls"], Usage::Parser.rewrite_multicall(nil, ["ls"], $PROGRAM_NAME, nil)
  end

  def test_arg_required_else_help
    root = Usage::Command.new(name: "ex", key: 1, arg_required_else_help: true)

    error = assert_raises(Usage::Help) { Usage::Parser.new(root, metadata(nil), []).parse }
    assert_equal "help requested", error.message
    assert_equal false, error.all
    assert_equal 1, error.cmd_key
    assert_equal false, error.long
  end

  def test_subcommand_can_negate_parent_requirements
    required = Usage::Flag.new(key: 2, name: "config", longs: ["config"], takes_value: true)
    child = Usage::Command.new(name: "run", key: 3)
    root = Usage::Command.new(name: "ex", key: 1, flags: [required], cmds: [child],
      cmd_negates_requirements: true)
    meta = metadata(nil, {key: 2, name: "config", flag: true, required: true}, nil)

    Usage::Parser.new(root, meta, ["run"]).parse
    error = assert_raises(Usage::Error) { Usage::Parser.new(root, meta, []).parse }
    assert_equal "missing required: config", error.message
  end

  def test_short_help_and_version_requests
    verbose = Usage::Flag.new(key: 2, name: "verbose", shorts: ["v"])
    root = Usage::Command.new(name: "ex", key: 1, flags: [verbose], version: true)

    {"-h" => Usage::Help, "-V" => Usage::Version, "-vh" => Usage::Help}.each do |token, error_class|
      error = assert_raises(error_class) { Usage::Parser.new(root, metadata(nil, nil), [token]).parse }
      message = (error_class == Usage::Help) ? "help requested" : "version requested"
      assert_equal message, error.message
      assert_equal false, error.long if error.is_a?(Usage::Help)
    end
  end

  def test_help_requests_keep_the_target_and_style
    short = Usage::Flag.new(key: 3, name: "short", longs: ["short"], action: :help_short)
    long = Usage::Flag.new(key: 4, name: "long", shorts: ["l"], action: :help_long)
    all = Usage::Flag.new(key: 5, name: "all", longs: ["all"], action: :help_all)
    install = Usage::Command.new(name: "install", key: 2)
    root = Usage::Command.new(name: "ex", key: 1, cmds: [install], flags: [short, long, all])
    meta = metadata(nil, nil, nil, nil, nil)

    cases = {
      ["--help"] => [1, true, false],
      ["--short"] => [1, false, false],
      ["-l"] => [1, true, false],
      ["--all"] => [1, true, true],
      %w[help install] => [2, true, false]
    }
    cases.each do |argv, expected|
      error = assert_raises(Usage::Help) { Usage::Parser.new(root, meta, argv).parse }
      assert_equal expected, [error.cmd_key, error.long, error.all]
    end
  end

  def test_declared_help_actions_and_disabled_synthetic_entries
    assist = Usage::Flag.new(key: 2, name: "assist", longs: ["assist"], action: :help_short)
    run = Usage::Command.new(key: 3, name: "run")
    root = Usage::Command.new(
      key: 1, name: "custom", cmds: [run], flags: [assist],
      disable_help_cmd: true, disable_help_flag: true
    )
    meta = metadata(nil, {key: 2, name: "assist", flag: true}, nil)

    help = assert_raises(Usage::Help) { Usage::Parser.new(root, meta, ["--assist"]).parse }
    refute help.long
    {"--help" => "unexpected argument: --help", "help" => "unexpected argument: help"}.each do |token, message|
      error = assert_raises(Usage::Error) { Usage::Parser.new(root, meta, [token]).parse }
      assert_instance_of Usage::Error, error
      assert_equal message, error.message
    end

    all = Usage::Flag.new(key: 2, name: "help-all", longs: ["help-all"], action: :help_all)
    recursive = Usage::Command.new(key: 1, name: "custom", flags: [all])
    all_meta = metadata(nil, {key: 2, name: "help-all", flag: true})
    help = assert_raises(Usage::Help) { Usage::Parser.new(recursive, all_meta, ["--help-all"]).parse }
    assert help.all
    assert help.long
  end

  def test_value_sources_follow_fill_order
    jobs = Usage::Flag.new(key: 2, name: "jobs", longs: ["jobs"], takes_value: true)
    root = Usage::Command.new(key: 1, name: "ex", flags: [jobs])
    meta = metadata(nil, {
      key: 2, name: "jobs", flag: true, env: "EX_JOBS",
      env_fallback: %w[OLD_JOBS OLDER_JOBS], deprecated_env: ["DEPRECATED_JOBS"], default: ["1"]
    })

    cases = [
      [["--jobs", "8"], {"EX_JOBS" => "4"}, ["8"], :argv],
      [[], {"EX_JOBS" => "4", "OLD_JOBS" => "3"}, ["4"], :env],
      [[], {"OLD_JOBS" => "3", "OLDER_JOBS" => "2"}, ["3"], :env],
      [[], {"DEPRECATED_JOBS" => "2"}, ["2"], :env],
      [[], {}, ["1"], :default],
      [[], {"EX_JOBS" => ""}, [""], :env]
    ]
    cases.each do |argv, env, values, source|
      parsed = Usage::Parser.new(root, meta, argv, env:).parse
      assert_equal values, parsed.values[2]
      assert_equal source, parsed.sources[2]
    end
  end

  def test_truthy_environment_allow_list
    %w[1 true True TRUE].each { assert Usage::Parser.truthy?(_1), _1 }
    ["0", "false", "", "yes", "on", "TrUe", "2"].each { refute Usage::Parser.truthy?(_1), _1 }
  end
end
