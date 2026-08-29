module Usage
  class Error < StandardError
  end

  class Help < Error
    attr_accessor(*%i[all cmd_key long])
  end

  class Version < Error
  end
end
