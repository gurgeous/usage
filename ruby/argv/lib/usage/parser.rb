module Usage
  class Parser
    HELP_SHORT = Flag.new(key: 0, name: "help", shorts: ["h"], action: :help_short)
    VERSION_SHORT = Flag.new(key: 0, name: "version", shorts: ["V"], action: :version)

    attr_reader(*%i[
      ancestors arg_filled arg_taken argv awaiting bound clauses cmd cmd_arg_found cmd_path
      cmd_starts collecting default_taken dont_delimit_trailing_values env
      external flags_stopped metadata sep_seen
    ])

    Bound = Struct.new(:values, :occurrences, :negated, :at) do
      def initialize
        super([], 0, false, 0)
      end
    end

    class << self
      def truthy?(value)
        %w[1 true True TRUE].include?(value)
      end

      def multicall_basename(argv0)
        argv0.to_s.split(/[\\\/]/).last.to_s.sub(/\.exe\z/i, "")
      end

      def rewrite_multicall(argv0, args, name, bin)
        argv0 ||= $PROGRAM_NAME
        base = multicall_basename(argv0)
        return args if [name, bin].compact.reject(&:empty?).any? { multicall_basename(_1) == base }

        [base, *args]
      end
    end

    def initialize(root, metadata, argv, env: ENV)
      @ancestors = []
      @arg_pos = @arg_taken = 0
      @argv = argv.dup
      @bound = {}
      @bundle = ""
      @clause_values = {}
      @clauses = Hash.new { _1[_2] = [] }
      @collecting = nil
      @cmd = root
      @cmd_path = [root]
      @cmd_starts = {root.key => 0}
      @dont_delimit_trailing_values = root.dont_delimit_trailing_values
      @env = env
      @external = []
      @metadata = metadata
      @pos = 0
      @seen = 0
    end

    def parse
      while @pos < argv.length || !@bundle.empty?
        step
      end
      finish_clause
      if cmd.arg_required_else_help && cmd_starts[cmd.key] == argv.length
        help!
      end
      resolve
    end

    private

    def step
      return short_flag unless @bundle.empty?

      if cmd.cmd_precedence_over_arg && !@flags_stopped &&
          (subcommand = find_named(cmd, argv[@pos]))
        conflict!(argv[@pos]) if cmd.args_conflict_with_cmds && @cmd_arg_found
        @pos += 1
        descend(subcommand)
        return
      end

      if @collecting && @pos < argv.length
        token = argv[@pos]
        if present?(@collecting.value_terminator) && token == @collecting.value_terminator
          @pos += 1
          @collecting = nil
          return step
        end
        can_collect = (!flag_like?(token) || (@collecting.allow_negative_numbers && negative_number?(token))) && token != "--"
        if can_collect
          @pos += 1
          bind_flag(@collecting, token, true)
          @collected += values_in(token, @collecting.delimiter)
          @collecting = nil if @collecting.var_max.to_i.positive? && @collected >= @collecting.var_max
          return
        end
        @collecting = nil
      end

      return if @pos >= argv.length

      token = argv[@pos]
      @pos += 1
      if !sep_seen && cmd.clause && token == cmd.clause.sep
        finish_clause
        @arg_pos = @arg_taken = 0
        @arg_filled = false
        @collecting = nil
        @flags_stopped = false
        return
      end
      return word(token) if @flags_stopped

      if token == "--"
        return word(token) if next_argument&.double_dash == :preserve

        @flags_stopped = @sep_seen = true
        required = current_arguments.each_index.find do |index|
          index >= @arg_pos && current_arguments[index].double_dash == :required
        end
        @arg_pos, @arg_taken = required, 0 if required
        return
      end

      if @arg_taken.positive? && (arg = next_argument) && present?(arg.value_terminator) && token == arg.value_terminator
        advance_argument
        return
      end

      numeric_short = token.length == 2 && token[1].match?(/\d/) && find_short(token[1])
      if negative_number?(token) && !numeric_short
        return word(token) if next_argument&.allow_negative_numbers
        return word(token) if cmd.external_cmd && !@arg_filled
      end

      if flag_like?(token)
        return long_flag(token) if token.start_with?("--")
        unless bundle_known?(token)
          raise Error, "unknown flag: #{token}" if cmd.unknown_flags == :error
          return word(token)
        end
        @bundle = token[1..]
        return short_flag
      end
      word(token)
    end

    def long_flag(token)
      name, attached = token[2..].split("=", 2)
      if (flag = find_long(name))
        value = nil
        if flag.takes_value
          value = attached.nil? ? detached_value(flag) : attached
        elsif flag.bool_value && !attached.nil?
          raise Error, "invalid value for #{flag.name}" unless %w[true false].include?(attached)
          value = attached
        end
        start_collecting(flag, value) if flag.variadic && !value.nil?
        return action!(flag, long: true) if flag.action && flag.action != :set
        return bind_flag(flag, value, !value.nil?)
      end
      if (flag = find_negation(name))
        if flag.bool_value && !attached.nil?
          raise Error, "invalid value for #{flag.name}" unless %w[true false].include?(attached)
          return bind_flag(flag, attached, true, true)
        end
        return bind_flag(flag, nil, false, true)
      end
      raise Version, "version requested" if name == "version" && cmd.version && !cmd.disable_version_flag
      help!(long: true) if name == "help" && !cmd.disable_help_flag
      raise Error, "unknown flag: #{token}" if cmd.unknown_flags == :error
      word(token)
    end

    def short_flag
      letter, rest = @bundle[0], @bundle[1..]
      flag = find_short(letter)
      action = flag.action && flag.action != :set
      unless flag.takes_value
        @bundle = rest
        if action
          @bundle = ""
          return action!(flag, long: false)
        end
        return bind_flag(flag, nil, false)
      end

      @bundle = ""
      value = case rest
      when "" then detached_value(flag)
      when /\A=/ then rest[1..]
      else rest
      end
      start_collecting(flag, value) if flag.variadic && !value.nil?
      return action!(flag, long: false) if action
      bind_flag(flag, value, !value.nil?)
    end

    def detached_value(flag)
      return missing_or_default(flag) if flag.require_equals
      if @pos < argv.length
        token = argv[@pos]
        if flag.allow_hyphen_values || !flag_like?(token) || (flag.allow_negative_numbers && negative_number?(token))
          @pos += 1
          return token
        end
      end
      missing_or_default(flag)
    end

    def missing_or_default(flag)
      return flag.default_missing if present?(flag.default_missing)
      return nil if flag.value_optional

      @awaiting = flag
      raise Error, "missing value for flag: #{flag.name}"
    end

    def action!(flag, long:)
      case flag.action
      when :help then help!(long:)
      when :help_short then help!
      when :help_long then help!(long: true)
      when :help_all then help!(all: true, long: true)
      when :version then raise Version, "version requested"
      end
    end

    def word(token)
      unless @arg_filled || @flags_stopped
        if (subcommand = find_named(cmd, token))
          conflict!(token) if cmd.args_conflict_with_cmds && @cmd_arg_found
          return descend(subcommand)
        end
        if token == "help" && !cmd.disable_help_cmd && !cmd.cmds.empty?
          help_command = cmd
          while @pos < argv.length && (subcommand = find_named(help_command, argv[@pos]))
            help_command = subcommand
            @pos += 1
          end
          help!(help_command, long: true)
        end
        default = cmd.default_cmd
        accepts_negative = default && negative_number?(token) && default.args.first&.allow_negative_numbers
        if default && !default_taken && (!flag_like?(token) || accepts_negative) && token != "--"
          @default_taken = true
          @pos -= 1
          descend(default)
          return
        end
        if (matched = match_sigil(token))
          return bind_sigil(token, matched)
        end
        if cmd.external_cmd && (!flag_like?(token) || negative_number?(token)) && !%w[-- -].include?(token)
          @external = [token, *argv[@pos..]]
          @pos = argv.length
          return
        end
      end

      if @arg_filled && (matched = match_sigil(token))
        return bind_sigil(token, matched)
      end

      skip_sigil_arguments
      reserve_for_required
      arg = next_argument
      raise Error, "unexpected argument: #{token}" unless arg
      raise Error, "argument requires a -- separator: #{arg.name}" if arg.double_dash == :required && !sep_seen

      @arg_filled = @cmd_arg_found = true
      trailing = sep_seen || arg.double_dash == :automatic
      delimit = !(dont_delimit_trailing_values && trailing)
      @flags_stopped = true if arg.double_dash == :automatic
      if arg.variadic
        @arg_taken += values_in(token, delimit ? arg.delimiter : nil)
        advance_argument if arg.var_max.to_i.positive? && @arg_taken >= arg.var_max
      else
        advance_argument
      end
      bind_argument(arg, token, delimit)
    end

    def bind_flag(flag, value, has_value, negated = false)
      @seen += 1
      item = (bound[flag.key] ||= Bound.new)
      item.occurrences += 1
      item.negated = negated
      item.at = @seen
      item.values.concat(split_value(value, flag.delimiter)) if has_value
      @cmd_arg_found = true
    end

    def bind_argument(arg, value, delimit = true)
      @seen += 1
      target = cmd.clause ? @clause_values : bound
      item = (target[arg.key] ||= Bound.new)
      item.occurrences += 1
      item.at = @seen
      item.values.concat(split_value(value, delimit ? arg.delimiter : nil))
    end

    def bind_sigil(token, matched)
      arg, sigil = matched
      raise Error, "invalid value for #{arg.name}: #{token}: expected a value after sigil #{sigil}" if token == sigil
      @cmd_arg_found = true
      bind_argument(arg, token[sigil.length..])
    end

    def descend(command)
      ancestors << cmd
      @cmd = command
      cmd_path << command
      cmd_starts[command.key] = @pos
      @dont_delimit_trailing_values ||= command.dont_delimit_trailing_values
      @arg_pos = @arg_taken = 0
      @arg_filled = @cmd_arg_found = false
    end

    def finish_clause
      return unless cmd.clause

      clauses[cmd.key] << @clause_values
      @clause_values = {}
    end

    def resolve
      lost, displaced = apply_overrides
      final, scope, ordered, requirements = {}, [], [], {}
      cmd_path.each_with_index do |command, index|
        check_requirements = index == cmd_path.length - 1 || !command.cmd_negates_requirements
        command.flags.each do |flag|
          ordered << flag.key
          requirements[flag.key] = check_requirements
          next if lost[flag.key]
          final[flag.key] = fill(flag.key, !flag.takes_value, bound[flag.key])
          scope << flag.key
        end
        command.args.each do |arg|
          ordered << arg.key
          requirements[arg.key] = check_requirements
          final[arg.key] = fill(arg.key, false, bound[arg.key])
          scope << arg.key
        end
      end
      apply_default_if(final, scope)
      ordered.each do |key|
        if lost[key]
          check_choices(metadata[key], displaced[key])
        else
          check_entry(metadata[key], final[key], requirements.fetch(key, true))
        end
      end
      check_relationships(final, scope, requirements)

      values, occurrences, negated, sources = {}, {}, {}, {}
      scope.each do |key|
        item = final[key]
        next if item[:source] == :unset
        values[key] = item[:values]
        occurrences[key], negated[key], sources[key] = item[:occurrences], item[:negated], item[:source]
      end
      Parsed.new(cmd_keys: cmd_path.map(&:key), values:,
        occurrences:, negated:, sources:,
        clauses: resolved_clauses(final), external:)
    end

    def fill(key, value_less, bound)
      meta = metadata[key]
      if bound && (!bound.values.empty? || value_less)
        return {values: bound.values, source: :argv, occurrences: bound.occurrences, negated: bound.negated}
      end
      if meta
        [meta[:env], *meta.fetch(:env_fallback, []), *meta.fetch(:deprecated_env, [])].compact.each do |name|
          if env.key?(name)
            values = fallback_values(meta, [env[name]])
            return {values:, source: :env, occurrences: bound&.occurrences.to_i, negated: bound&.negated}
          end
        end
        unless meta.fetch(:default_if, []).any?
          defaults = meta.fetch(:default, [])
          unless defaults.empty?
            return {values: fallback_values(meta, defaults), source: :default, occurrences: 0, negated: false}
          end
        end
      end
      {values: [], source: :unset, occurrences: bound&.occurrences.to_i, negated: bound&.negated}
    end

    def apply_overrides
      lost = {}
      bound.each do |key, item|
        metadata[key].fetch(:overrides, []).each do |other|
          next unless bound[other]
          if bound[other].at < item.at
            lost[other] = true
          elsif item.at < bound[other].at
            lost[key] = true
          end
        end
      end
      displaced = lost.to_h { [_1, bound[_1].values] }
      [lost, displaced]
    end

    def apply_default_if(final, scope)
      scope.each do |key|
        item, meta = final[key], metadata[key]
        next unless item[:source] == :unset && meta
        condition = meta.fetch(:default_if, []).find do |entry|
          selector = final[entry[:key]]
          next false unless selector && %i[argv env].include?(selector[:source])
          !entry.key?(:when) || relationship_values(metadata[entry[:key]], selector).include?(entry[:when])
        end
        values = condition ? [condition[:value]] : meta.fetch(:default, [])
        next if values.empty?
        item[:values], item[:source] = fallback_values(meta, values), :default
      end
    end

    def check_entry(meta, item, check_requirements = true)
      raise Error, "flag given more than once: #{meta[:name]}" if meta[:reject_duplicate] && item[:occurrences] > 1
      if check_requirements && meta[:required] && item[:values].empty? && item[:occurrences].zero?
        missing!(meta)
      end
      check_choices(meta, item[:values])
      if meta[:validate] && !item[:values].empty?
        raise Error, "validation expressions are not supported for #{meta[:name]}"
      end
      if meta[:var_min].to_i.positive? && !item[:values].empty? && item[:values].length < meta[:var_min]
        raise Error, "too few values for #{meta[:name]}"
      end
      if meta[:var_max].to_i.positive? && item[:occurrences] > meta[:var_max]
        raise Error, "too many occurrences of #{meta[:name]}"
      end
    end

    def check_choices(meta, values)
      return unless meta
      accepted = meta.fetch(:accepted_choices, meta.fetch(:choices, []))
      return if accepted.empty? || meta[:allow_unknown_choices]
      invalid = values.find do |value|
        !accepted.any? { _1 == value || (meta[:ignore_case] && _1.ascii_only? && value.ascii_only? && _1.casecmp?(value)) }
      end
      raise Error, "invalid value for #{meta[:name]}" if invalid
    end

    def check_relationships(final, scope, requirements)
      given = ->(key) { final[key] && %i[argv env].include?(final[key][:source]) }
      scope.each do |key|
        meta, item = metadata[key], final[key]
        next unless meta
        if given.call(key)
          meta.fetch(:conflicts, []).each do |other|
            raise Error, "#{meta[:name]} cannot be given with #{metadata[other]&.dig(:name)}" if given.call(other)
          end
          next unless requirements.fetch(key, true)

          meta.fetch(:requires, []).each { missing!(metadata[_1]) unless final[_1] && final[_1][:source] != :unset }
          values = relationship_values(meta, item)
          meta.fetch(:requires_if, []).each do |condition|
            missing!(metadata[condition[:key]]) if values.include?(condition[:value]) && (!final[condition[:key]] || final[condition[:key]][:source] == :unset)
          end
          next
        end
        next unless item[:source] == :unset
        next unless requirements.fetch(key, true)
        next if meta[:required]

        unless_any = meta.fetch(:required_unless, []).any?(&given)
        unless_all_keys = meta.fetch(:required_unless_all, [])
        unless_all = !unless_all_keys.empty? && unless_all_keys.all?(&given)
        missing!(meta) if (!meta.fetch(:required_unless, []).empty? || !unless_all_keys.empty?) && !(unless_any || unless_all)
        missing!(meta) if meta.fetch(:required_if, []).any?(&given)
        matches = ->(condition) { given.call(condition[:key]) && relationship_values(metadata[condition[:key]], final[condition[:key]]).include?(condition[:value]) }
        missing!(meta) if meta.fetch(:required_if_eq, []).any?(&matches)
        all = meta.fetch(:required_if_eq_all, [])
        missing!(meta) if !all.empty? && all.all?(&matches)
      end
    end

    def relationship_values(meta, item)
      return item[:values] unless meta && meta[:boolean]
      case item[:source]
      when :argv
        value = item[:values].empty? || item[:values].last == "true"
        [(value != item[:negated]).to_s]
      when :env then [self.class.truthy?(item[:values].last).to_s]
      when :default then [(item[:values].last == "true").to_s]
      else item[:values]
      end
    end

    def resolved_clauses(final)
      cmd_path.each_with_object({}) do |command, result|
        next unless command.clause

        scope = command.clause.args.map(&:key)
        result[command.key] = clauses.fetch(command.key, []).map do |instance|
          clause_final = scope.to_h { [_1, fill(_1, false, instance[_1])] }
          combined = final.merge(clause_final)
          apply_default_if(combined, scope)
          scope.each { check_entry(metadata[_1], combined[_1]) }
          check_relationships(combined, scope, scope.to_h { [_1, true] })
          scope.each_with_object({}) do |key, values|
            values[key] = combined[key][:values] unless combined[key][:source] == :unset
          end
        end
      end
    end

    def advance_argument
      skip_sigil_arguments
      @arg_pos += 1
      @arg_taken = 0
      skip_sigil_arguments
    end

    def skip_sigil_arguments
      @arg_pos += 1 while @arg_pos < current_arguments.length && present?(current_arguments[@arg_pos].sigil)
    end

    def reserve_for_required
      return unless cmd.allow_missing_positional && @arg_taken.zero?
      while (arg = current_arguments[@arg_pos]) && !arg.required
        required = current_arguments[(@arg_pos + 1)..].count { _1.required && !present?(_1.sigil) }
        return if required.zero?
        remaining = 1 + argv[@pos..].count { (@flags_stopped || !flag_like?(_1)) && !match_sigil(_1) }
        return if remaining > required
        advance_argument
      end
    end

    def match_sigil(token)
      return if @flags_stopped

      args = current_arguments + ancestors.reverse.flat_map(&:args)
      arg = args.select { present?(_1.sigil) && token.start_with?(_1.sigil) }.max_by { _1.sigil.length }
      arg && [arg, arg.sigil]
    end

    def flags_in_scope
      cmd.flags + ancestors.reverse.flat_map { _1.flags.select(&:global) }
    end

    def find_short(letter)
      flags_in_scope.find { _1.shorts.include?(letter) } ||
        (HELP_SHORT if letter == "h" && !cmd.disable_help_flag) ||
        (VERSION_SHORT if letter == "V" && cmd.version && !cmd.disable_version_flag)
    end

    def find_named(command, name)
      command.cmds.find { _1.name == name } || command.cmds.find { _1.aliases.include?(name) }
    end

    def help!(command = cmd, all: false, long: false)
      error = Help.new("help requested")
      error.all, error.cmd_key, error.long = all, command.key, long
      raise error
    end

    def bundle_known?(token)
      token[1..].chars.each do |letter|
        flag = find_short(letter)
        return false unless flag
        return true if flag.takes_value
      end
      true
    end

    def start_collecting(flag, first)
      @collected = values_in(first, flag.delimiter)
      @collecting = flag unless flag.var_max.to_i.positive? && flag.var_max <= 1
    end

    def split_value(value, delimiter)
      present?(delimiter) ? value.split(delimiter, -1) : [value]
    end

    def fallback_values(meta, values)
      values = values.flat_map { split_value(_1, meta[:delimiter]) }
      meta[:variadic] ? values : values.first(1)
    end

    # one-liners
    def conflict!(token) = raise Error, "subcommand conflicts with an earlier argument: #{token}"
    def current_arguments = cmd.clause ? cmd.clause.args : cmd.args
    def find_long(name) = flags_in_scope.find { _1.longs.include?(name) }
    def find_negation(name) = flags_in_scope.find { present?(_1.negate) && _1.negate == name }
    def flag_like?(token) = token.length > 1 && token.start_with?("-")
    def missing!(meta) = raise Error, "missing required: #{meta[:name]}"
    def negative_number?(token) = token.match?(/\A-(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)
    def next_argument = current_arguments[@arg_pos..]&.find { !present?(_1.sigil) }
    def pending_arg = next_argument
    def present?(value) = !value.nil? && value != ""
    def subcommands_possible? = !arg_filled && !flags_stopped
    def values_in(value, delimiter) = split_value(value, delimiter).length

    public :pending_arg, :subcommands_possible?
  end
end
