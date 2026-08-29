module Usage
  class HelpPages
    module Layout
      BLOCK_INDENT = 4
      MIN_INLINE_HELP_WIDTH = 30

      def entry(out, usage, text, col, next_line, page_width)
        indent = 2 + col + 2
        room = [page_width - indent, 0].max
        overflow = width(usage) > col
        inline_start = overflow ? 2 + width(usage) + 2 : indent
        inline_room = page_width - inline_start
        inline = !next_line && ((overflow && inline_room >= MIN_INLINE_HELP_WIDTH) || (!overflow && room >= 10))
        stack_indent = (!next_line && page_width - indent >= 10) ? indent : BLOCK_INDENT

        if text.to_s.strip.empty?
          out << "  #{usage}\n"
          return inline ? indent : stack_indent
        end
        unless inline
          out << "  #{usage}\n"
          write_wrapped(out, text, page_width, stack_indent)
          return stack_indent
        end

        lines = overflow ? wrap_at(text, inline_room, room) : wrap(text, room)
        out << "  #{overflow ? usage : pad(usage, col)}  #{lines.shift}\n"
        lines.each { out << (_1.empty? ? "\n" : "#{" " * indent}#{_1}\n") }
        indent
      end

      def write_wrapped(out, text, page_width, indent)
        prefix = " " * indent
        wrap(text, page_width - indent).each do |line|
          out << (line.empty? ? "\n" : "#{prefix}#{line}\n")
        end
      end

      def wrap_at(text, first_width, continuation_width)
        text.split("\n", -1).each_with_index.flat_map do |line, index|
          wrap(line, index.zero? ? first_width : continuation_width)
        end
      end

      def wrap(text, line_width)
        lines = text.split("\n", -1).flat_map do |paragraph|
          next [""] if paragraph.empty?
          next [paragraph] if paragraph.start_with?("    ", "\t")

          indent = paragraph[/\A */]
          prefix, body = list_prefix(paragraph.lstrip)
          if prefix.empty?
            body = paragraph.strip
          else
            prefix = indent + prefix
          end
          body_width = [line_width - width(prefix), 0].max
          wrapped = []
          line = +""
          line_prefix = prefix
          body.split.each do |word|
            if !line.empty? && width(line) + 1 + width(word) > body_width
              wrapped << line_prefix + line
              line = +""
              line_prefix = " " * width(prefix)
            end
            line << " " unless line.empty?
            line << word
          end
          wrapped << line_prefix + line unless line.empty?
          wrapped
        end
        lines.empty? ? [""] : lines
      end

      def list_prefix(line)
        marker = %w[*\  -\  +\ ].find { line.start_with?(_1) }
        return [marker, line.delete_prefix(marker)] if marker

        match = line.match(/\A(\d+\. )(.*)\z/)
        match ? [match[1], match[2]] : ["", line]
      end

      def usage_column_width(longest, page_width)
        return longest if page_width.infinite?

        [longest, (page_width - 4) * 2 / 5].min
      end

      def pad(text, col)
        text + (" " * [col - width(text), 0].max)
      end

      def width(text)
        text.length
      end
    end
  end
end
