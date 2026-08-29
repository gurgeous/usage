module Usage
  class HelpPages
    include Layout
    include UsageLine
    include Helpers

    attr_reader(*%i[commands entries root spec])

    def initialize(root, spec, entries)
      @commands = {}
      @entries = entries
      @root = root
      @spec = spec
      walk = lambda do |cmd, path, chain|
        commands[cmd.key] = [path, chain]
        cmd.cmds.each { walk.call(_1, path + [_1.name], chain + [_1]) }
      end
      path = spec.bin.to_s.empty? ? [] : [spec.bin]
      walk.call(root, path, [root])
    end

    def fetch(key, long:)
      path, chain = commands.fetch(key)
      page(path, chain, long:)
    end

    def render(error)
      path, chain = commands.fetch(error.cmd_key)
      return all_pages(path, chain) if error.all

      page(path, chain, long: error.long)
    end

    def page(path, chain, long:)
      cmd = chain.last
      meta = entries[cmd.key]
      page_width = terminal_width(meta)
      sections = Sections.new
      out = sections.about

      before = if long
        first(meta&.fetch(:before_long_help, nil), meta&.fetch(:before_help, nil), spec.before_long_help, spec.before_help)
      else
        meta&.fetch(:before_help, nil) || spec.before_help
      end
      unless before.to_s.empty?
        write_wrapped(out, before, page_width, 0)
        out << "\n"
      end
      root_page = chain.length == 1
      if root_page && spec.version
        out << "#{spec.name || spec.bin} #{spec.version}\n"
      end
      about = if root_page
        long ? first(spec.long_about, spec.about) : spec.about
      elsif long
        first(meta&.fetch(:long, nil), meta&.fetch(:short, nil))
      else
        meta&.fetch(:short, nil)
      end
      unless about.to_s.rstrip.empty?
        write_wrapped(out, about.rstrip, page_width, 0)
        out << "\n"
      end
      label = deprecation_label(meta)
      unless label.empty?
        write_wrapped(out, label, page_width, 0)
        out << "\n"
      end

      usage_lines(path, cmd).each_with_index do |line, index|
        sections.usage << (index.zero? ? "Usage: " : "       ") << line << "\n"
      end
      relative_path = spec.bin.to_s.empty? ? path : path.drop(1)
      commands_section(sections.commands, relative_path, cmd, long:, page_width:) unless meta&.fetch(:flatten_help, false)
      if long
        long_arguments(sections, cmd, meta, page_width)
        long_flags(sections, chain, meta, page_width)
      else
        short_arguments(sections, cmd, meta, page_width)
        short_flags(sections, chain, meta, page_width)
      end
      if meta&.fetch(:flatten_help, false)
        flat_commands(sections.flattened, relative_path, cmd, long:, next_line: meta&.fetch(:next_line_help, false), page_width:)
      end
      if long
        long_footer(sections.after_help, chain, meta, page_width)
      else
        short_examples(sections.after_help, page_examples(chain, meta))
        after = meta&.fetch(:after_help, nil) || spec.after_help
        unless after.to_s.empty?
          sections.after_help << "\n"
          write_wrapped(sections.after_help, after, page_width, 0)
        end
      end
      sections.assemble(spec.help_template)
    end

    def all_pages(path, chain)
      pages = [page(path, chain, long: true)]
      order_commands(chain.last.cmds.reject { hidden?(_1.key) }).each do |child|
        pages << all_pages(path + [child.name], chain + [child])
      end
      pages.join("\n")
    end

    private

    def short_arguments(sections, cmd, meta, page_width)
      args = visible_positionals(cmd, long: false)
      col = usage_column_width(args.map { width(arg_usage(_1)) }.max || 0, page_width)
      next_line = meta&.fetch(:next_line_help, false)
      groups_section(
        sections.args, sections.ungrouped_args, sections.grouped_args,
        "Arguments", args, page_width:
      ) do |action, arg, out|
        if action == :heading
          heading_of(arg.key)
        elsif next_line
          item = entries[arg.key]
          out << "  #{arg_usage(arg)}\n"
          text = with_annotations(item&.fetch(:short, ""), [deprecation_label(item)])
          write_wrapped(out, text, page_width, 4) unless text.empty?
          long_annotations(out, item, default: true, indent: 4, page_width:)
        else
          item = entries[arg.key]
          entry(out, arg_usage(arg), with_annotations(item&.fetch(:short, ""), annotations(item, default: true)), col, false, page_width)
        end
      end
    end

    def short_flags(sections, chain, meta, page_width)
      own, inherited = own_and_global(chain)
      own = filter_help_mode(own, long: false)
      inherited = filter_help_mode(inherited, long: false)
      col = usage_column_width((own + inherited).map { width(_1.usage) }.max || 0, page_width)
      next_line = meta&.fetch(:next_line_help, false)
      writer = lambda do |flag, out|
        if flag.supplied
          if next_line
            out << "  #{flag.usage}\n"
            write_wrapped(out, flag.supplied_help, page_width, 4)
          else
            entry(out, flag.usage, flag.supplied_help, col, false, page_width)
          end
          next
        end
        item = entries[flag.key]
        if next_line
          out << "  #{flag.usage}\n"
          write_wrapped(out, item[:short], page_width, 4) if item&.fetch(:short, nil)
          long_annotations(out, item, default: true, indent: 4, page_width:)
        else
          text = with_annotations(item&.fetch(:short, ""), annotations(item, default: true, deprecation: true))
          entry(out, flag.usage, text, col, false, page_width)
        end
      end
      flag_groups(sections, own, "Flags", writer, page_width:)
      flag_groups(sections, inherited, "Global flags", writer, grouped: false, page_width:)
    end

    def long_arguments(sections, cmd, meta, page_width)
      args = visible_positionals(cmd, long: true)
      col = usage_column_width(args.map { width(arg_usage(_1)) }.max || 0, page_width)
      next_line = meta&.fetch(:next_line_help, false)
      groups_section(
        sections.args, sections.ungrouped_args, sections.grouped_args,
        "Arguments", args, page_width:, prose: heading_prose(meta)
      ) do |action, arg, out|
        if action == :heading
          heading_of(arg.key)
        else
          item = entries[arg.key]
          indent = entry(out, arg_usage(arg), first(item&.fetch(:long, nil), item&.fetch(:short, nil)), col, next_line, page_width)
          long_annotations(out, item, default: true, indent:, page_width:)
        end
      end
    end

    def long_flags(sections, chain, meta, page_width)
      own, inherited = own_and_global(chain)
      own = filter_help_mode(own, long: true)
      inherited = filter_help_mode(inherited, long: true)
      col = usage_column_width((own + inherited).map { width(_1.usage) }.max || 0, page_width)
      next_line = meta&.fetch(:next_line_help, false)
      writer = lambda do |flag, out|
        if flag.supplied
          entry(out, flag.usage, flag.supplied_help, col, next_line, page_width)
        else
          item = entries[flag.key]
          indent = entry(out, flag.usage, first(item&.fetch(:long, nil), item&.fetch(:short, nil)), col, next_line, page_width)
          long_annotations(out, item, default: true, indent:, page_width:)
        end
      end
      flag_groups(sections, own, "Flags", writer, prose: heading_prose(meta), page_width:)
      flag_groups(sections, inherited, "Global flags", writer, grouped: false, page_width:)
    end

    def flag_groups(sections, flags, title, writer, page_width:, grouped: true, prose: nil)
      groups_section(
        sections.flags, sections.ungrouped_flags, sections.grouped_flags,
        title, flags, page_width:, prose:
      ) do |action, flag, out|
        if action == :heading
          (grouped && !flag.supplied) ? heading_of(flag.key) : ""
        else
          writer.call(flag, out)
        end
      end
    end

    def flat_commands(out, path, cmd, long:, next_line:, page_width:)
      order_commands(cmd.cmds).each do |sub|
        item = entries[sub.key]
        next if hidden?(sub.key)
        subpath = path + [sub.name]
        out << "\n#{subpath.join(" ")}:\n"
        about = long ? first(item&.fetch(:long, nil), item&.fetch(:short, nil)) : item&.fetch(:short, nil)
        write_wrapped(out, about.rstrip, page_width, 0) unless about.to_s.strip.empty?
        label = deprecation_label(item)
        write_wrapped(out, label, page_width, 0) unless label.empty?

        args = visible_positionals(sub, long:)
        flags = sub.flags.reject { _1.global || hidden?(_1.key) || entries[_1.key]&.fetch(long ? :hide_long_help : :hide_short_help, false) }
        arg_col = usage_column_width(args.map { width(arg_usage(_1)) }.max || 0, page_width)
        flag_col = usage_column_width(flags.map { width(column_usage(_1)) }.max || 0, page_width)
        args.each do |arg|
          meta = entries[arg.key]
          text = if long
            first(meta&.fetch(:long, nil), meta&.fetch(:short, nil))
          elsif next_line
            meta&.fetch(:short, "")
          else
            with_annotations(meta&.fetch(:short, ""), annotations(meta, default: true))
          end
          indent = entry(out, arg_usage(arg), text, arg_col, next_line, page_width)
          long_annotations(out, meta, default: true, indent:, page_width:) if long || next_line
        end
        positions = sub.flags.each_with_index.to_h
        flags.sort_by { [help_order(_1.key, positions[_1]), positions[_1]] }.each do |flag|
          meta = entries[flag.key]
          text = if long
            first(meta&.fetch(:long, nil), meta&.fetch(:short, nil))
          elsif next_line
            meta&.fetch(:short, "")
          else
            with_annotations(meta&.fetch(:short, ""), annotations(meta, default: true, deprecation: true))
          end
          indent = entry(out, column_usage(flag), text, flag_col, next_line, page_width)
          long_annotations(out, meta, default: true, indent:, page_width:) if long || next_line
        end
        if item&.fetch(:flatten_help, false)
          flat_commands(out, subpath, sub, long:, next_line: item[:next_line_help], page_width:)
        end
      end
    end

    def short_examples(out, examples)
      return if examples.empty?
      out << "\nExamples:\n"
      examples.each do |example|
        out << "  #{example[:header]}:\n" if example[:header]
        out << "    $ #{example[:code]}\n"
      end
    end

    def long_footer(out, chain, meta, page_width)
      examples = page_examples(chain, meta)
      unless examples.empty?
        out << "\nExamples:\n"
        examples.each do |example|
          out << "  #{example[:header]}:\n" if example[:header]
          out << "    #{example[:help]}\n" if example[:help]
          out << "    $ #{example[:code]}\n"
        end
      end
      after = first(meta&.fetch(:after_long_help, nil), meta&.fetch(:after_help, nil), spec.after_long_help, spec.after_help)
      unless after.to_s.empty?
        out << "\n"
        write_wrapped(out, after, page_width, 0)
      end
      if spec.author || spec.license
        out << "\n"
        out << "Author: #{spec.author}\n" if spec.author
        out << "License: #{spec.license}\n" if spec.license
      end
    end

    def terminal_width(meta)
      if meta&.key?(:term_width)
        return Float::INFINITY if meta[:term_width].zero?

        return meta[:term_width]
      end

      detected = Integer(ENV.fetch("COLUMNS", "80"), exception: false) || 80
      detected = 80 if detected.negative?
      max = meta&.fetch(:max_term_width, nil)
      (!max || max.zero?) ? detected : [detected, max].min
    end

    def first(*values)
      values.find { !_1.to_s.empty? }
    end
  end
end
