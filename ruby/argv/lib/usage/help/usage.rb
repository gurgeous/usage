module Usage
  class HelpPages
    module UsageLine
      INLINE_LIMIT = 2
      SHORT_COL = 4

      Shown = Struct.new(*%i[long negate short]) do
        def nothing?
          !long && !short && !negate
        end
      end
      ShownFlag = Struct.new(*%i[key supplied supplied_help usage])

      def usage_line(path, cmd, include_cmds: true)
        out = path.join(" ")
        flags = cmd.flags.reject { hidden?(_1.key) }
        unless flags.empty?
          if flags.length <= INLINE_LIMIT
            flags.each do |flag|
              demanded = entries[flag.key]&.fetch(:demanded, false)
              out << " #{demanded ? "<" : "["}#{flag_usage(flag)}#{demanded ? ">" : "]"}"
            end
          else
            out << ((flags.any? { entries[_1.key]&.fetch(:demanded, false) }) ? " <FLAGS>" : " [FLAGS]")
          end
        end

        args = visible_positionals(cmd, long: nil)
        unless args.empty?
          if cmd.clause
            inner = args.map { arg_usage(_1) }.join(" ")
            out << " #{inner} [#{cmd.clause.sep} #{inner}]…"
          elsif args.length <= INLINE_LIMIT
            args.each { out << " #{arg_usage(_1)}" }
          else
            out << ((args.any? { entries[_1.key]&.fetch(:demanded, false) }) ? " <ARGS>…" : " [ARGS]…")
          end
        end

        if include_cmds && !cmd.cmds.empty?
          name = entries[cmd.key]&.fetch(:subcommand_value_name, nil) || "SUBCOMMAND"
          out << " <#{name}>"
        end
        out
      end

      def usage_lines(path, cmd)
        meta = entries[cmd.key]
        return [usage_line(path, cmd)] unless meta&.fetch(:flatten_help, false)

        visible = cmd.cmds.reject { hidden?(_1.key) }
        return [usage_line(path, cmd)] if visible.empty?

        lines = []
        unless meta[:subcommand_required] && !cmd.args_conflict_with_cmds
          lines << usage_line(path, cmd, include_cmds: false)
        end
        order_commands(visible).each { lines << usage_line(path + [_1.name], _1) }
        lines
      end

      def flag_usage(flag, shown = all_shown(flag))
        meta = entries[flag.key]
        parts = []
        implied = shown.long == flag.name || (!shown.long && shown.short == flag.name)
        parts << "#{flag.name}:" unless implied
        parts << "-#{shown.short}" if shown.short
        parts << "--#{shown.long}" if shown.long
        out = parts.join(" ")
        if flag.takes_value
          name = meta&.fetch(:value_name, nil) || flag.name
          open, close = meta&.fetch(:value_demanded, false) ? %w[< >] : %w[[ ]]
          names = meta&.fetch(:value_names, nil)
          arity = meta&.fetch(:value_arity, nil)
          names = Array.new(arity, name) if (!names || names.length <= 1) && arity.to_i > 1
          if names && names.length > 1
            names.each { out << " #{open}#{_1}#{close}" }
          else
            out << " #{open}#{name}#{close}"
          end
          out << "…" if flag.variadic && (!names || names.length <= 1) && arity.to_i.zero?
        end
        out
      end

      def arg_usage(arg)
        meta = entries[arg.key]
        open, close = meta&.fetch(:demanded, false) ? %w[< >] : %w[[ ]]
        names = meta&.fetch(:value_names, nil)
        arity = meta&.fetch(:value_arity, nil)
        if (names && names.length > 1) || arity.to_i > 1
          names = Array.new(arity, names&.first || arg.name) if !names || names.length <= 1
          prefix = (arg.double_dash == :required) ? "-- " : ""
          out = prefix + names.map { "#{open}#{_1}#{close}" }.join(" ")
        elsif arg.double_dash == :required
          out = "#{open}-- #{arg.name}#{close}"
        else
          out = "#{open}#{arg.name}#{close}"
        end
        out << "…" if arg.variadic && (!names || names.length <= 1) && arity.to_i.zero?
        out
      end

      def all_shown(flag)
        Shown.new(
          long: flag.longs.find { !flag.hidden_longs.include?(_1) },
          short: flag.shorts.find { !flag.hidden_shorts.include?(_1) },
          negate: !flag.negate.nil?
        )
      end

      def column_usage(flag, shown = all_shown(flag))
        usage = flag_usage(flag, shown)
        usage << " / --#{flag.negate}" if shown.negate && flag.negate
        return usage unless shown.long

        at = usage.index("--#{shown.long}")
        return usage unless at
        before, after = usage[...at], usage[at..]
        short = before.strip
        bare_short = short.start_with?("-") && !short.start_with?("--") && width(short) == 2
        return usage if !short.empty? && !bare_short

        short << "," unless short.empty?
        pad(short, SHORT_COL) + after
      end

      def visible_positionals(cmd, long:)
        args = cmd.clause ? cmd.clause.args : cmd.args
        args = args.reject do |arg|
          meta = entries[arg.key]
          meta && (meta[:hide] || (long == false && meta[:hide_short_help]) || (long && meta[:hide_long_help]))
        end
        positions = args.each_with_index.to_h
        args.sort_by { [help_order(_1.key, positions[_1]), positions[_1]] }
      end

      def own_and_global(chain)
        here = chain.last
        ancestors = chain[...-1]
        every_form = every_form_in_scope(chain)
        taken = here.flags.flat_map { forms_of(_1) }
        taken_negations = here.flags.filter_map { negation_of(_1) }
        own = here.flags.reject { hidden?(_1.key) }.map do |flag|
          ShownFlag.new(key: flag.key, usage: column_usage(flag))
        end

        keep = {}
        ancestors.reverse_each do |ancestor|
          ancestor.flags.each do |flag|
            next unless flag.global
            shown = surviving(flag, taken, taken_negations, every_form)
            taken.concat(forms_of(flag))
            taken_negations << negation_of(flag) if negation_of(flag)
            keep[flag] = shown unless hidden?(flag.key) || shown.nothing?
          end
        end
        inherited = ancestors.flat_map do |ancestor|
          ancestor.flags.filter_map do |flag|
            shown = keep[flag]
            ShownFlag.new(key: flag.key, usage: column_usage(flag, shown)) if shown
          end
        end
        own = order_shown(own)
        inherited = order_shown(inherited)
        claimed = taken + taken_negations
        [own + supplied_entries(here, claimed), inherited]
      end

      def supplied_entries(cmd, claimed)
        entries = []
        entries << supplied_entry("help", "h", "Print help", claimed) unless cmd.disable_help_flag
        if cmd.version && !cmd.disable_version_flag
          entries << supplied_entry("version", "V", "Print version", claimed)
        end
        entries.compact
      end

      def supplied_entry(long, short, text, claimed)
        has_long = !claimed.include?("--#{long}")
        has_short = !claimed.include?("-#{short}")
        return unless has_long || has_short

        usage = if !has_long
          "-#{short}"
        elsif !has_short
          "#{pad("", SHORT_COL)}--#{long}"
        else
          "#{pad("-#{short},", SHORT_COL)}--#{long}"
        end
        ShownFlag.new(supplied: long, supplied_help: text, usage:)
      end

      def surviving(flag, taken, taken_negations, every_form)
        long = flag.longs.find { !flag.hidden_longs.include?(_1) && !taken.include?("--#{_1}") }
        short = flag.shorts.find { !flag.hidden_shorts.include?(_1) && !taken.include?("-#{_1}") }
        negation = negation_of(flag)
        negate = negation && !taken_negations.include?(negation) &&
          (!every_form.include?(negation) || forms_of(flag).include?(negation))
        Shown.new(long:, short:, negate:)
      end

      def every_form_in_scope(chain)
        chain.last.flags.flat_map { forms_of(_1) } + chain[...-1].flat_map do |cmd|
          cmd.flags.select(&:global).flat_map { forms_of(_1) }
        end
      end

      def forms_of(flag)
        flag.longs.map { "--#{_1}" } + flag.shorts.map { "-#{_1}" }
      end

      def negation_of(flag)
        "--#{flag.negate}" if flag.negate
      end

      def filter_help_mode(flags, long:)
        flags.reject do |flag|
          meta = entries[flag.key]
          meta && (long ? meta[:hide_long_help] : meta[:hide_short_help])
        end
      end

      def order_shown(flags)
        positions = flags.each_with_index.to_h { [_1.key, _2] }
        flags.sort_by { [help_order(_1.key, positions[_1.key]), positions[_1.key]] }
      end

      def order_commands(commands)
        commands.sort_by { [help_order(_1.key, 999), _1.name] }
      end

      def help_order(key, fallback)
        meta = entries[key]
        meta&.fetch(:display_order_set, false) ? meta[:display_order] : fallback
      end

      def hidden?(key)
        entries[key]&.fetch(:hide, false)
      end
    end
  end
end
