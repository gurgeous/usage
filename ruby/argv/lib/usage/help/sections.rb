module Usage
  class HelpPages
    # The named pieces accepted by a spec's help template.
    class Sections
      NAMES = %i[
        about usage commands args flags grouped_args ungrouped_args
        grouped_flags ungrouped_flags after_help
      ]
      STYLES = %w[
        heading option metavar black red green yellow blue magenta cyan white
        bright-black bright-red bright-green bright-yellow bright-blue
        bright-magenta bright-cyan bright-white bold dim italic underline
      ]

      attr_reader(*NAMES, :flattened)

      def initialize
        (NAMES + [:flattened]).each { instance_variable_set(:"@#{_1}", +"") }
      end

      def assemble(template)
        page = concatenated
        page = substitute(template) unless template.to_s.strip.empty?
        "#{page.strip}\n"
      end

      def named(name)
        return unless NAMES.include?(name.to_sym)

        if name == "commands"
          return [commands.strip, flattened.strip].reject(&:empty?).join("\n\n")
        end
        public_send(name).strip
      end

      private

      def concatenated
        [about, usage, commands, args, flags, flattened, after_help].join
      end

      def substitute(template)
        return collapse_blank_runs(substitute_sections(template)) unless valid_style_markup?(template)

        rest = template.dup
        out = +""
        loop do
          token = next_token(rest, true)
          return collapse_blank_runs(out << rest) unless token

          at, kind, _ = token
          out << rest.slice!(0, at)
          case kind
          when :section
            close = rest.index("}}", 2)
            return collapse_blank_runs(out << rest) unless close

            placeholder = rest.slice!(0, close + 2)
            value = named(placeholder[2...-2].strip)
            out << (value.nil? ? placeholder : value)
          when :open
            close = rest.index("}")
            return collapse_blank_runs(out << rest) unless close
            rest.slice!(0, close + 1)
          when :close then rest.slice!(0, 4)
          when :escape_open
            out << "{$"
            rest.slice!(0, 3)
          when :escape_close
            out << "{/$}"
            rest.slice!(0, 5)
          end
        end
      end

      def substitute_sections(template)
        template.gsub(/\{\{(.*?)\}\}/m) do |placeholder|
          value = named(Regexp.last_match(1).strip)
          value.nil? ? placeholder : value
        end
      end

      def valid_style_markup?(template)
        rest = template
        depth = 0
        while (token = next_token(rest, false))
          at, kind, = token
          rest = rest[at..]
          case kind
          when :escape_open then rest = rest[3..]
          when :escape_close then rest = rest[5..]
          when :open
            close = rest.index("}")
            return false unless close && close > 2
            return false unless rest[2...close].split("+").all? { STYLES.include?(_1) }
            depth += 1
            rest = rest[(close + 1)..]
          when :close
            return false if depth.zero?
            depth -= 1
            rest = rest[4..]
          end
        end
        depth.zero?
      end

      def next_token(text, sections)
        tokens = {
          "{$$" => :escape_open, "{/$$}" => :escape_close,
          "{$" => :open, "{/$}" => :close
        }
        tokens["{{"] = :section if sections
        found = tokens.filter_map do |token, kind|
          at = text.index(token)
          [at, kind, token] if at
        end
        found.min_by(&:first)
      end

      def collapse_blank_runs(page)
        out = []
        blank = false
        page.split("\n", -1).each do |line|
          if line.strip.empty?
            blank = !out.empty?
          else
            out << "" if blank
            out << line
            blank = false
          end
        end
        out.join("\n")
      end
    end
  end
end
