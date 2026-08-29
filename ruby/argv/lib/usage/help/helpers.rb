module Usage
  class HelpPages
    module Helpers
      HELP_SUBCOMMAND = "help"
      HELP_SUBCOMMAND_SUMMARY = "Print this message or the help of the given subcommand(s)"

      def commands_section(out, path, cmd, long:, page_width:)
        lines = cmd.cmds.reject { hidden?(_1.key) }.map do |sub|
          [usage_line(path + [sub.name], sub), sub]
        end
        return if lines.empty?

        meta = entries[cmd.key]
        heading = meta&.fetch(:subcommand_help_heading, nil) || "Commands"
        next_line = meta&.fetch(:next_line_help, false)
        lines.sort_by! { |usage, sub| [help_order(sub.key, 999), usage] }
        show_help = !cmd.disable_help_cmd
        col = ([show_help ? width(HELP_SUBCOMMAND) : 0] + lines.map { width(_1[1].name) }).max
        col = usage_column_width(col, page_width)
        headings = [""]
        lines.each do |_, sub|
          item_heading = heading_of(sub.key)
          headings << item_heading if !item_heading.empty? && item_heading != heading && !headings.include?(item_heading)
        end
        headings.each do |section|
          title = section.empty? ? heading : section
          out << "\n#{title}:\n"
          if long && !section.empty? && (prose = heading_prose(meta, section))
            write_wrapped(out, prose, page_width, 2)
            out << "\n"
          end
          lines.each do |_, sub|
            item_section = heading_of(sub.key)
            item_section = "" if item_section == heading
            next unless item_section == section
            entry(out, sub.name, command_row(entries[sub.key]), col, next_line, page_width)
          end
          entry(out, HELP_SUBCOMMAND, HELP_SUBCOMMAND_SUMMARY, col, next_line, page_width) if section.empty? && show_help
        end
      end

      def groups_section(out, ungrouped, grouped, default_title, items, page_width:, prose: nil)
        return if items.empty?

        grouped_items = items.map { [_1, yield(:heading, _1)] }
        headings = grouped_items.map(&:last).uniq
        headings.sort_by! { _1.empty? ? 0 : 1 }
        headings.each do |heading|
          section = "\n#{heading.empty? ? default_title : heading}:\n"
          if !heading.empty? && prose && (text = prose.call(heading)) && !text.empty?
            write_wrapped(section, text, page_width, 2)
            section << "\n"
          end
          grouped_items.each { |item, item_heading| yield(:write, item, section) if item_heading == heading }
          out << section
          (heading.empty? ? ungrouped : grouped).concat(section)
        end
      end

      def command_row(meta)
        return "" unless meta

        parts = []
        summary = meta.fetch(:short, "").rstrip
        summary = meta.fetch(:long, "").lines.first.to_s.rstrip if summary.empty?
        parts << summary unless summary.empty?
        aliases = meta.fetch(:visible_aliases, [])
        parts << "[aliases: #{aliases.join(", ")}]" unless aliases.empty?
        label = deprecation_label(meta)
        parts << label unless label.empty?
        parts.join(" ")
      end

      def annotations(meta, default:, deprecation: false, long: false)
        return [] unless meta

        parts = []
        choices = meta.fetch(:choices, [])
        unless meta[:hide_possible_values] || choices.empty?
          parts << (long ? "[possible values: #{choices.join(", ")}]" : "[#{choices.join(", ")}]")
        end
        unless meta[:hide_env]
          parts << "[env: #{meta[:env]}]" if meta[:env]
          meta.fetch(:env_fallback, []).each { parts << "[env fallback: #{_1}]" }
          meta.fetch(:deprecated_env, []).each { parts << "[deprecated env: #{_1}]" }
        end
        values = meta.fetch(:default, [])
        parts << "(default: #{values.join(", ")})" if default && !meta[:hide_default_value] && !values.empty?
        label = deprecation_label(meta)
        parts << label if deprecation && !label.empty?
        parts
      end

      def long_annotations(out, meta, default:, indent:, page_width:)
        annotations(meta, default:, deprecation: true, long: true).each do
          write_wrapped(out, _1, page_width, indent)
        end
      end

      def with_annotations(text, values)
        ([text.to_s.rstrip] + values).reject(&:empty?).join(" ")
      end

      def deprecation_label(meta)
        return "" unless meta

        parts = []
        parts << meta[:deprecated] if meta[:deprecated]
        parts << "warns at #{meta[:deprecated_warn_at]}" if meta[:deprecated_warn_at]
        parts << "removed at #{meta[:deprecated_remove_at]}" if meta[:deprecated_remove_at]
        parts.empty? ? "" : "[deprecated: #{parts.join("; ")}]"
      end

      def heading_of(key)
        entries[key]&.fetch(:heading, "") || ""
      end

      def heading_prose(meta, title = nil)
        return unless meta
        headings = meta.fetch(:headings, [])
        return headings.find { _1[:title] == title }&.fetch(:help) if title
        return if headings.empty?
        ->(name) { headings.find { _1[:title] == name }&.fetch(:help, nil) }
      end

      def page_examples(chain, meta)
        examples = meta&.fetch(:examples, []) || []
        return examples unless examples.empty?
        entries[chain.first.key]&.fetch(:examples, []) || []
      end
    end
  end
end
