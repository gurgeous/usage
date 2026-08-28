require_relative "test_helper"

class ParserTest < Minitest::Test
  def test_flags_arguments_and_subcommands
    force = Usage::Flag.new(key: 3, name: "force", longs: ["force"])
    package = Usage::Argument.new(key: 4, name: "package", required: true)
    install = Usage::Command.new(name: "install", key: 2, flags: [force], arguments: [package])
    verbose = Usage::Flag.new(key: 5, name: "verbose", shorts: ["v"], global: true)
    root = Usage::Command.new(name: "", key: 1, flags: [verbose], subcommands: [install], unknown_flags: :error)
    meta = metadata(nil, nil, {key: 3, name: "force", flag: true, boolean: true},
      {key: 4, name: "package", required: true},
      {key: 5, name: "verbose", flag: true, boolean: true})

    parsed = Usage::Parser.new(root, meta, %w[-v install --force rack]).parse

    assert_equal [1, 2], parsed.command_keys
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
    root = Usage::Command.new(name: "", key: 1, arguments: [port])
    meta = metadata(nil, {key: 2, name: "port", validate: "int(value) > 0"})

    Usage::Parser.new(root, meta, []).parse
    error = assert_raises(Usage::Error) { Usage::Parser.new(root, meta, ["1"]).parse }
    assert_equal "validation expressions are not supported for port", error.message
  end

  def test_multicall_rewrite
    assert_equal %w[ls -l], Usage::Parser.rewrite_multicall("/usr/bin/ls", ["-l"], "busybox", "busybox")
    assert_equal %w[ls -l], Usage::Parser.rewrite_multicall("C:\\bin\\ls.exe", ["-l"], "busybox", "busybox")
    assert_equal ["ls"], Usage::Parser.rewrite_multicall("busybox", ["ls"], "busybox", "busybox")
    assert_equal ["ls"], Usage::Parser.rewrite_multicall(nil, ["ls"], $PROGRAM_NAME, nil)
  end

  def test_arg_required_else_help
    root = Usage::Command.new(name: "ex", key: 1, arg_required_else_help: true)

    error = assert_raises(Usage::Error) { Usage::Parser.new(root, metadata(nil), []).parse }
    assert_equal "help requested", error.message
  end

  def test_subcommand_can_negate_parent_requirements
    required = Usage::Flag.new(key: 2, name: "config", longs: ["config"], takes_value: true)
    child = Usage::Command.new(name: "run", key: 3)
    root = Usage::Command.new(name: "ex", key: 1, flags: [required], subcommands: [child],
      subcommand_negates_requirements: true)
    meta = metadata(nil, {key: 2, name: "config", flag: true, required: true}, nil)

    Usage::Parser.new(root, meta, ["run"]).parse
    error = assert_raises(Usage::Error) { Usage::Parser.new(root, meta, []).parse }
    assert_equal "missing required: config", error.message
  end

  def test_short_help_and_version_requests
    verbose = Usage::Flag.new(key: 2, name: "verbose", shorts: ["v"])
    root = Usage::Command.new(name: "ex", key: 1, flags: [verbose], version: true)

    {"-h" => "help requested", "-V" => "version requested", "-vh" => "help requested"}.each do |token, message|
      error = assert_raises(Usage::Error) { Usage::Parser.new(root, metadata(nil, nil), [token]).parse }
      assert_equal message, error.message
    end
  end
end
