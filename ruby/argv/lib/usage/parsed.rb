# The result of a parse: values keyed by parse-table key, plus where each came from.
module Usage
  class Parsed
    attr_reader(*%i[clauses cmd_keys external negated occurrence_counts sources values])

    def initialize(cmd_keys:, values:, occurrences:, negated:, sources:, clauses:, external: [])
      @clauses = clauses
      @cmd_keys = cmd_keys
      @external = external
      @negated = negated
      @occurrence_counts = occurrences
      @sources = sources
      @values = values
    end

    # A flag's boolean value, which depends on its source: argv honors negation,
    # env parses truthy strings, defaults are already stringified.
    def boolean(key)
      case sources[key]
      when :argv
        entries = values.fetch(key, [])
        entries.empty? ? !negated[key] : (entries.last == "true") != negated[key]
      when :env then Parser.truthy?(values.fetch(key).last)
      when :default then values.fetch(key, []).last == "true"
      else false
      end
    end

    def occurrences(key)
      occurrence_counts.fetch(key, 0)
    end
  end
end
