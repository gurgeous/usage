module Usage
  Command = Struct.new(*%i[
    aliases allow_missing_positional arg_required_else_help arguments
    arguments_conflict_with_subcommands clause default_subcommand
    disable_help_flag disable_help_subcommand disable_version_flag
    dont_delimit_trailing_values external_subcommand flags key name
    subcommand_negates_requirements subcommand_precedence_over_argument
    subcommands unknown_flags version
  ]) do
    def initialize(key:, name:, **)
      super
      self.aliases ||= []
      self.arguments ||= []
      self.flags ||= []
      self.subcommands ||= []
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
    def initialize(key:, name:, **) = super
  end

  Clause = Struct.new(*%i[arguments key name separator]) do
    def initialize(key:, name:, separator:, **)
      super
      self.arguments ||= []
    end
  end

  class Metadata
    attr_reader :entries

    def initialize(entries)
      @entries = entries
    end

    def [](key)
      return if key <= 0

      entry = entries[key - 1]
      entry if entry && entry[:key] == key
    end
  end
end
