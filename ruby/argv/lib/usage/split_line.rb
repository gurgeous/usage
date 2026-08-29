# Splits a shell command line at the cursor the way the shell would, yielding the
# words before the cursor and the partial word under it.
module Usage
  class SplitLine
    attr_reader(*%i[cword prefix words])

    # A cursor past the end means end of line, and one landing inside a multi-byte
    # character moves back to its start — a completion request is no place to be strict.
    def initialize(line, cursor: nil, shell: :bash)
      cursor = line.bytesize if cursor.nil? || cursor.negative? || cursor > line.bytesize
      cursor -= 1 while cursor.positive? && continuation_byte?(line.getbyte(cursor))

      @cword, @prefix, @words = split(line, cursor, shell)
    end

    # Words after the binary and before the cursor: what the parser walks.
    def argv
      words[[1, cword].min...cword]
    end

    private

    # Scans char by char tracking quote state, recording the word index and partial
    # prefix as soon as the cursor byte offset is reached. `started` distinguishes an
    # empty quoted word from whitespace, so `"" <cursor>` still yields a word.
    def split(line, cursor, shell)
      chars = line.each_char.to_a
      offsets = [0]
      chars.each { offsets << offsets.last + _1.bytesize }
      words = []
      word = +""
      cword = 0
      prefix = +""
      # `started` is whether anything was written into `word`, including a quote holding
      # nothing, so that `ex ""` is a word rather than a gap.
      found = cursor_in_word = started = false
      quote = nil
      index = 0

      # Called before the character it precedes is read, and again before an escape takes
      # the next one — otherwise a cursor on an escaped character goes unnoticed and the
      # split describes the previous word.
      reached = lambda do |offset|
        next unless offset == cursor && !found

        cword = words.length
        prefix = word.dup
        found = true
        cursor_in_word = started
      end

      while index < chars.length
        char = chars[index]
        reached.call(offsets[index])
        following = chars[index + 1]

        if quote == "'"
          if char == "'"
            if shell == :powershell && following == "'"
              reached.call(offsets[index + 1])
              word << "'"
              index += 1
            else
              quote = nil
            end
          else
            word << char
          end
        elsif quote
          if char == quote
            if shell == :powershell && following == quote
              reached.call(offsets[index + 1])
              word << quote
              index += 1
            else
              quote = nil
            end
          elsif escape?(char, shell) && following && escapable_in_quotes?(following, shell)
            reached.call(offsets[index + 1])
            word << following
            index += 1
          else
            word << char
          end
        elsif %w[' "].include?(char)
          quote = char
          started = true
        elsif escape?(char, shell)
          started = true
          if following
            reached.call(offsets[index + 1])
            word << following
            index += 1
          end
        elsif whitespace?(char)
          if started
            words << word
            word = +""
            started = false
          end
        else
          word << char
          started = true
        end
        index += 1
      end

      # The cursor sat at the end of the line.
      unless found
        cword = words.length
        prefix = word.dup
        cursor_in_word = started
      end
      words << word if started
      # A cursor in the gap between words is completing one not typed yet, so make it.
      words.insert(cword, "") unless cursor_in_word
      [cword, prefix, words]
    end

    # one-liners
    def continuation_byte?(byte) = byte && byte & 0xc0 == 0x80
    def escapable_in_quotes?(char, shell) = (shell == :powershell) ? %w[" ` $].include?(char) : %w[" \\ $ `].include?(char)
    def escape?(char, shell) = char == ((shell == :powershell) ? "`" : "\\")
    def whitespace?(char) = [" ", "\t", "\n", "\r", "\v", "\f"].include?(char)
  end
end
