# Completion candidates and their shell-specific wire format. The file markers are
# control-character lines the completion scripts strip out to pick a file mode.
module Usage
  COMPLETION_MARKERS = {
    any: "\x01files",
    commands: "\x01commands",
    dirs: "\x01dirs",
    executables: "\x01executables"
  }

  CompletionCandidate = Struct.new(*%i[description kind value])

  CompletionAnswer = Struct.new(*%i[candidates files]) do
    # Renders candidates for the shell, appending the file-mode marker if any.
    def render(shell)
      available = candidates.select { travels?(_1.value) }
      described = available.any? { !_1.description.to_s.empty? }
      out = available.map { render_candidate(_1, shell, described) }.join
      marker = COMPLETION_MARKERS[files]
      marker ? "#{out}#{marker}\n" : out
    end

    private

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

    def zsh_quote(value)
      return value if value.match?(/\A[A-Za-z0-9_.\-\/:@+=%,]+\z/)

      "'#{value.gsub("'", "'\\\\''")}'"
    end

    # one-liners
    def travels?(value) = value.each_byte.none? { _1 < 0x20 || _1 == 0x7f }
  end
end
