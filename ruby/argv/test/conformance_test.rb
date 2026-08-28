require "digest"
require "json"
require "open3"
require_relative "test_helper"

class ConformanceTest < Minitest::Test
  CORPUS = File.expand_path("../../../corpus", __dir__)
  USAGE = ENV.fetch("USAGE_BIN", File.expand_path("../../../target/debug/usage", __dir__))
  ERROR_MESSAGES = {
    "arg_requires_double_dash" => "argument requires a -- separator:",
    "conflicting_flags" => "cannot be given with",
    "invalid_choice" => "invalid value for",
    "invalid_value" => "invalid value for",
    "missing_flag_value" => "missing value for flag:",
    "missing_required_arg" => "missing required:",
    "missing_required_flag" => "missing required:",
    "unexpected_arg" => "unexpected argument:",
    "unknown_flag" => "unknown flag:",
    "var_too_few" => "too few values for",
    "var_too_many" => "too many occurrences of"
  }

  Vector = Data.define(:data, :mod, :shape)

  def test_shared_argv_corpus
    failures = []
    vectors.each do |vector|
      data = vector.data
      begin
        actual = parse(vector)
        if (code = data.dig("expect", "error"))
          failures << "#{data["id"]}: expected #{code}, parsed #{actual.inspect}"
          next
        end
        expected = normalize(data.dig("expect", "ok"))
        failures << "#{data["id"]}: expected #{expected.inspect}, got #{normalize(actual).inspect}" unless expected == normalize(actual)
      rescue Usage::Error => error
        expected = data.dig("expect", "error")
        message = ERROR_MESSAGES.fetch(expected)
        failures << "#{data["id"]}: expected #{expected.inspect}, got #{error.message.inspect}" unless error.message.include?(message)
      end
    end
    assert_empty failures, failures.join("\n")
  end

  private

  def vectors
    @vectors ||= Dir[File.join(CORPUS, "*.json")].sort.flat_map do |path|
      JSON.parse(File.read(path), symbolize_names: false).fetch("vectors").map do |data|
        spec = resolved_spec(data)
        Vector.new(data:, mod: generated_module(data, spec), shape: lowered_spec(data, spec))
      end
    end
  end

  def generated_module(data, spec)
    name = "UsageCorpus#{Digest::SHA256.hexdigest(spec)[0, 16]}"
    return Object.const_get(name) if Object.const_defined?(name, false)

    source, stderr, status = Open3.capture3(USAGE, "generate", "ruby", "--spec", spec, "--module", name)
    raise "generating #{data["id"]}: #{stderr}" unless status.success?

    eval(source, TOPLEVEL_BINDING, "#{name}.rb") # standard:disable Security/Eval
    Object.const_get(name)
  end

  def lowered_spec(data, spec)
    @lowered_specs ||= {}
    @lowered_specs[spec] ||= begin
      source, stderr, status = Open3.capture3(USAGE, "generate", "json", "--spec", spec)
      raise "lowering #{data["id"]}: #{stderr}" unless status.success?

      JSON.parse(source)
    end
  end

  def resolved_spec(data)
    spec = data.fetch("spec")
    data.fetch("mounts", {}).each do |command, output|
      body = output.lines.reject { _1.match?(/\A(?:name|bin)\s/) }.join.rstrip
      pattern = /^(\s*)mount\s+run="#{Regexp.escape(command)}"[^\n]*$/
      spec = spec.sub(pattern) do
        indent = Regexp.last_match(1)
        next "" if indent.empty? && spec.match?(/^default_subcommand\s/) && !Regexp.last_match(0).include?("overrides_default=#true")

        body.lines.map { "#{indent}#{_1}" }.join.rstrip
      end
    end
    spec
  end

  def parse(vector)
    data, mod = vector.data, vector.mod
    args = data.fetch("argv").dup
    if data.fetch("spec").match?(/^multicall\s+#true$/)
      name = data.fetch("spec")[/^name\s+"([^"]+)"$/, 1]
      bin = data.fetch("spec")[/^bin\s+"([^"]+)"$/, 1]
      args = Usage::Parser.rewrite_multicall(data["argv0"] || bin || name, args, name, bin)
    end
    parsed = Usage::Parser.new(mod::ROOT, mod::META, args, env: data.fetch("env", {})).parse
    render(mod::ROOT, mod::META, parsed, vector.shape)
  end

  def render(root, metadata, parsed, shape)
    commands = command_path(root, parsed.command_keys)
    shapes = commands.drop(1).each_with_object([shape.fetch("cmd")]) do |command, path|
      path << path.last.fetch("subcommands").fetch(command.name)
    end
    flags, arguments, clauses = {}, {}, {}
    commands.zip(shapes).each do |command, command_shape|
      command.flags.each do |flag|
        next unless parsed.values.key?(flag.key)

        meta = metadata[flag.key]
        flag_shape = command_shape.fetch("flags").find { _1.fetch("name") == flag.name }
        flags[flag.name] = if flag_shape["count"]
          Array.new(parsed.occurrences(flag.key), true)
        elsif meta[:boolean]
          parsed.boolean(flag.key)
        elsif flag_shape["var"] || flag_shape.dig("arg", "var")
          parsed.values[flag.key]
        else
          parsed.values[flag.key].last
        end
      end
      command.arguments.each do |argument|
        next unless parsed.values.key?(argument.key)

        arguments[argument.name] = argument.variadic ? parsed.values[argument.key] : parsed.values[argument.key].last
      end
      next unless command.clause

      clauses[command.clause.name] = parsed.clauses.fetch(command.key, []).map do |instance|
        command.clause.arguments.each_with_object({}) do |argument, values|
          next unless instance.key?(argument.key)
          values[argument.name] = argument.variadic ? instance[argument.key] : instance[argument.key].last
        end
      end
    end
    {
      "cmd" => commands.drop(1).map(&:name), "flags" => flags, "args" => arguments,
      "clauses" => clauses, "external" => parsed.external
    }
  end

  def command_path(root, keys)
    keys.drop(1).each_with_object([root]) do |key, path|
      path << path.last.subcommands.find { _1.key == key }
    end
  end

  def normalize(result)
    result ||= {}
    {
      "cmd" => result.fetch("cmd", []),
      "flags" => result.fetch("flags", {}),
      "args" => result.fetch("args", {}),
      "clauses" => result.fetch("clauses", {}),
      "external" => result.fetch("external", [])
    }
  end
end
