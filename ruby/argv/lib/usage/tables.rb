# The parse-table structs a generated CLI hands to the parser, plus the sidecar
# metadata/help tables looked up by the same integer keys.
module Usage
  # One command node. Most fields are policies the parser reads at the single
  # decision point each governs; `key` indexes the metadata tables.
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

  # A flag declaration: its spellings, whether it takes a value, and how that value
  # may be written. Hidden longs/shorts still parse, they just do not complete.
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

  # A positional declaration. `sigil` marks one matched by prefix (`+tag`), and
  # `double_dash` says how it relates to a `--` separator.
  Argument = Struct.new(*%i[
    allow_negative_numbers delimiter double_dash key name required sigil
    value_terminator var_max variadic
  ]) do
    def initialize(key:, name:, **)
      super
    end
  end

  # A repeating group of positionals; every `sep` in argv starts a new instance.
  Clause = Struct.new(*%i[args key name sep]) do
    def initialize(key:, name:, sep:, **)
      super
      self.args ||= []
    end
  end

  # Keys are 1-based indices into entries; the stored key is re-checked so a table
  # that omits entries yields nil rather than the wrong one.
  Metadata = Struct.new(:entries) do
    def [](key)
      return if key <= 0

      entry = entries[key - 1]
      entry if entry && entry[:key] == key
    end
  end

  # Descriptions, aliases, and hidden marks, keyed like Metadata and read only while
  # completing.
  CompletionMetadata = Struct.new(:entries) do
    def [](key)
      return if key <= 0

      entry = entries[key - 1]
      entry if entry && entry[:key] == key
    end
  end

  # Root fields used by every help page.
  HelpSpec = Struct.new(*%i[
    about after_help after_long_help author before_help before_long_help bin
    help_template license long_about name version
  ])

  # Semantic help metadata, keyed like the parse and binding tables.
  HelpMetadata = Struct.new(:entries) do
    def [](key)
      return unless key&.positive?

      entry = entries[key - 1]
      entry if entry && entry[:key] == key
    end
  end
end
