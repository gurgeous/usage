module Usage
  CompletionPosition = Struct.new(*%i[
    arg_values awaiting collecting cmd cmd_path external flags_possible
    help_topic next_arg restarted sep_seen subcommands_possible
  ])

  class Completer
    REQUEST = "__complete_word__"
    SHELLS = %i[bash fish nu powershell zsh]

    attr_reader(*%i[completion metadata root])

    def initialize(root, metadata, completion)
      @completion = completion
      @metadata = metadata
      @root = root
    end

    def answer(line, cursor: nil, shell: :bash)
      shell = normalize_shell(shell)
      split = SplitLine.new(line, cursor:, shell:)
      position = walk(split.argv)
      found = candidates(position, split.prefix)
      CompletionAnswer.new(candidates: found, files: files_at(position, split.prefix, found))
    end

    def respond(args)
      request = parse_request(args)
      return unless request

      answer(request[:line], cursor: request[:cursor], shell: request[:shell]).render(request[:shell])
    end

    private

    def walk(words)
      parser = Parser.new(root, metadata, words, env: {})
      help = nil
      begin
        parser.parse
      rescue Help => error
        help = error
      rescue Error
        nil
      end

      cmd = help ? command_with_key(root, help.cmd_key) : parser.cmd
      restarted = cmd.restart_token && words.last == cmd.restart_token
      CompletionPosition.new(
        arg_values: restarted ? 0 : parser.arg_taken,
        awaiting: restarted ? nil : parser.awaiting,
        collecting: restarted ? nil : parser.collecting,
        cmd:,
        cmd_path: parser.cmd_path,
        external: !parser.external.empty?,
        flags_possible: restarted || !parser.flags_stopped,
        help_topic: !help.nil?,
        next_arg: restarted ? arguments(cmd).find { !_1.sigil } : parser.pending_arg,
        restarted:,
        sep_seen: restarted ? false : parser.sep_seen,
        subcommands_possible: restarted || parser.subcommands_possible?
      )
    end

    def candidates(position, partial)
      return [] if position.external
      return value_candidates(position.awaiting, partial) if position.awaiting
      return command_candidates(position.cmd, partial) if position.help_topic

      attached = attached_value(position, partial)
      return attached if attached

      found = []
      collecting = !position.collecting.nil?
      found.concat(value_candidates(position.collecting, partial)) if collecting
      if position.subcommands_possible && !collecting
        found.concat(command_candidates(position.cmd, partial))
      end
      if position.flags_possible && partial.start_with?("-")
        found.concat(flag_candidates(position.cmd_path, partial))
      end
      if position.next_arg && !collecting &&
          !(position.next_arg.double_dash == :required && !position.sep_seen)
        found.concat(value_candidates(position.next_arg, partial))
      end
      deduplicate(found)
    end

    def command_candidates(cmd, partial)
      cmd.cmds.each_with_object([]) do |subcommand, found|
        details = completion[subcommand.key]
        next if details&.dig(:hidden)

        [subcommand.name, *details&.fetch(:aliases, [])].compact.each do |name|
          next unless name.start_with?(partial)

          found << CompletionCandidate.new(
            description: details&.dig(:description), kind: :command, value: name
          )
        end
      end
    end

    def flag_candidates(path, partial)
      flags_in_scope(path).each_with_object([]) do |entry, found|
        flag, forms = entry
        details = completion[flag.key]
        next if details&.dig(:hidden)

        forms.each do |form|
          next unless form.start_with?(partial)

          found << CompletionCandidate.new(
            description: details&.dig(:description), kind: :flag, value: form
          )
        end
      end
    end

    def value_candidates(entry, partial)
      return [] unless entry

      metadata[entry.key]&.fetch(:choices, [])&.filter_map do |value|
        CompletionCandidate.new(description: nil, kind: :value, value:) if value.start_with?(partial)
      end || []
    end

    def attached_value(position, partial)
      form, value = partial.split("=", 2)
      return unless value && form.start_with?("--")

      flag = flags_in_scope(position.cmd_path).map(&:first).find do |candidate|
        candidate.takes_value && candidate.longs.include?(form.delete_prefix("--"))
      end
      return [] unless flag

      value_candidates(flag, value).each { _1.value = "#{form}=#{_1.value}" }
    end

    def flags_in_scope(path)
      every_form = path.flat_map.with_index do |command, index|
        command.flags.filter_map { forms(_1) if index == path.length - 1 || _1.global }
      end.flatten
      taken = []
      taken_negations = []
      found = []
      commands = [path.last, *path[...-1].reverse]
      commands.each_with_index do |command, index|
        command.flags.each do |flag|
          next if index.positive? && !flag.global

          visible = visible_forms(flag).reject { taken.include?(_1) }
          negation = flag.negate && "--#{flag.negate}"
          if negation && !visible.include?(negation) && !taken.include?(negation) &&
              !taken_negations.include?(negation) &&
              (!every_form.include?(negation) || forms(flag).include?(negation))
            visible << negation
          end
          taken.concat(forms(flag))
          taken_negations << negation if negation
          found << [flag, visible] unless visible.empty?
        end
      end
      found
    end

    def files_at(position, partial, found)
      return if position.external
      return if position.flags_possible && partial.start_with?("-")
      if !position.awaiting && !position.collecting && position.next_arg&.double_dash == :required && !position.sep_seen
        return
      end

      entry = position.awaiting || position.collecting || position.next_arg
      details = entry && metadata[entry.key]
      named = details&.dig(:value_name) || entry&.name
      if (type = details&.dig(:complete_type))
        declared = declared_files(type, position)
        return declared if declared
        return unless type.casecmp?("unknown")
      end
      return files_for(named) if files_for(named)

      choices = details && (!details.fetch(:choices, []).empty? || !details.fetch(:accepted_choices, []).empty?)
      return if !found.empty? || choices || position.help_topic

      :any
    end

    def parse_request(args)
      return unless args.first == REQUEST

      request = {shell: :bash, line: "", cursor: nil}
      index = 1
      while index < args.length
        case args[index]
        when "--shell"
          request[:shell] = normalize_shell(args[index += 1]) if args[index + 1]
        when "--line"
          request[:line] = args[index += 1] if args[index + 1]
        when "--cursor"
          request[:cursor] = Integer(args[index += 1], exception: false) if args[index + 1]
        end
        index += 1
      end
      request[:cursor] = request[:line].bytesize unless request[:cursor]&.between?(0, request[:line].bytesize)
      request
    end

    def command_with_key(command, key)
      return command if command.key == key

      command.cmds.each do |child|
        found = command_with_key(child, key)
        return found if found
      end
      nil
    end

    def files_for(name)
      case name&.downcase
      when "file", "path", "config_file" then :any
      when "dir", "directory" then :dirs
      when "executable" then :executables
      when "command" then :commands
      end
    end

    def declared_files(name, position)
      return position.arg_values.to_i.zero? ? :commands : :any if name.casecmp?("command_args")

      files_for(name)
    end

    def normalize_shell(shell)
      shell = shell.to_s.downcase.to_sym
      case shell
      when :nushell then :nu
      when :pwsh then :powershell
      when *SHELLS then shell
      else :bash
      end
    end

    def forms(flag)
      [*flag.longs.map { "--#{_1}" }, *flag.shorts.map { "-#{_1}" }]
    end

    def visible_forms(flag)
      longs = flag.longs.reject { flag.hidden_longs.include?(_1) }.map { "--#{_1}" }
      shorts = flag.shorts.reject { flag.hidden_shorts.include?(_1) }.map { "-#{_1}" }
      [*longs, *shorts]
    end

    # one-liners
    def arguments(cmd) = cmd.clause ? cmd.clause.args : cmd.args
    def deduplicate(candidates) = candidates.uniq(&:value)
  end
end
