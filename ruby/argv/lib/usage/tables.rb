module Usage
  Command = Struct.new(*%i[
    aliases allow_missing_positional arg_required_else_help args
    args_conflict_with_cmds clause cmd_negates_requirements
    cmd_precedence_over_arg cmds default_cmd disable_help_cmd
    disable_help_flag disable_version_flag dont_delimit_trailing_values
    external_cmd flags key name restart_token unknown_flags version
  ]) do
    def initialize(key:, name:, **)
      super
      self.aliases ||= []
      self.args ||= []
      self.cmds ||= []
      self.flags ||= []
      self.unknown_flags ||= :value
    end
  end

  Flag = Struct.new(*%i[
    action allow_hyphen_values allow_negative_numbers bool_value
    default_missing delimiter global hidden_longs hidden_shorts key longs name
    negate require_equals shorts takes_value value_optional value_terminator
    var_max variadic
  ]) do
    def initialize(key:, name:, **)
      super
      self.hidden_longs ||= []
      self.hidden_shorts ||= []
      self.longs ||= []
      self.shorts ||= []
    end
  end

  Argument = Struct.new(*%i[
    allow_negative_numbers delimiter double_dash key name required sigil
    value_terminator var_max variadic
  ]) do
    def initialize(key:, name:, **)
      super
    end
  end

  Clause = Struct.new(*%i[args key name sep]) do
    def initialize(key:, name:, sep:, **)
      super
      self.args ||= []
    end
  end

  Metadata = Struct.new(:entries) do
    def [](key)
      return if key <= 0

      entry = entries[key - 1]
      entry if entry && entry[:key] == key
    end
  end

  CompletionMetadata = Struct.new(:entries) do
    def [](key)
      return if key <= 0

      entry = entries[key - 1]
      entry if entry && entry[:key] == key
    end
  end

  HelpPage = Struct.new(*%i[children long short])

  HelpPages = Struct.new(:entries) do
    def fetch(key, long:)
      page = entries.fetch(key)
      long ? page.long : page.short
    end

    def render(error)
      return fetch(error.cmd_key, long: error.long) unless error.all

      render_all(error.cmd_key)
    end

    def render_all(key)
      page = entries.fetch(key)
      ([page.long] + page.children.map { render_all(_1) }).join("\n")
    end
  end
end
