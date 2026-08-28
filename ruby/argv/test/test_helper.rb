require "minitest/autorun"
require "usage"

module UsageTest
  def metadata(*entries)
    Usage::Metadata.new(entries)
  end
end

Minitest::Test.include(UsageTest)
