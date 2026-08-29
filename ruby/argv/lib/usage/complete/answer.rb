# Completion candidates and their shell-specific wire format. The file markers are
# control-character lines the completion scripts strip out to pick a file mode.
module Usage
  module Complete
    MARKERS = {
      any: "\x01files",
      commands: "\x01commands",
      dirs: "\x01dirs",
      executables: "\x01executables"
    }

    Candidate = Struct.new(*%i[description kind value])
    ExtensionFiles = Struct.new(:extensions)

    Answer = Struct.new(*%i[candidates files]) do
      # Renders candidates for the shell, appending the file-mode marker if any.
      def render(shell)
        available = candidates.select { travels?(_1.value) }
        described = available.any? { !_1.description.to_s.empty? }
        out = available.map { render_candidate(_1, shell, described) }.join
        marker = if files.is_a?(ExtensionFiles)
          "\x01extensions\t#{files.extensions.join("\t")}"
        else
          MARKERS[files]
        end
        marker ? "#{out}#{marker}\n" : out
      end

      private

      # zsh takes three tab-separated columns (display, description, insert); the others
      # take a value and an optional description, but only if some candidate has one.
      def render_candidate(candidate, shell, described)
        description = one_line(candidate.description)
        case shell
        when :bash
          "#{candidate.value}\n"
        when :zsh
          "#{candidate.value}\t#{description}\t#{zsh_quote(candidate.value)}\n"
        else
          suffix = described ? "\t#{description}" : ""
          "#{candidate.value}#{suffix}\n"
        end
      end

      # Collapses control characters to single spaces so a description stays one line.
      def one_line(value)
        output = +""
        spaced = false
        value.to_s.each_char do |char|
          if char.ord < 0x20 || char.ord == 0x7f
            output << " " if !spaced && !output.empty?
            spaced = true
          else
            output << char
            spaced = false
          end
        end
        output.rstrip
      end

      # zsh inserts this column verbatim, so anything the shell would re-read is quoted.
      def zsh_quote(value)
        return value if value.match?(/\A[A-Za-z0-9_.\-\/:@+=%,]+\z/)

        "'#{value.gsub("'", "'\\\\''")}'"
      end

      # one-liners
      # Candidates are newline- and tab-separated on the wire, so a value holding either
      # would be read back as two; it is dropped rather than mangled.
      def travels?(value) = value.each_byte.none? { _1 < 0x20 || _1 == 0x7f }
    end
  end
end
