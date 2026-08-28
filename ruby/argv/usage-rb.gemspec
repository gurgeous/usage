require_relative "lib/usage/version"

Gem::Specification.new do |spec|
  spec.name = "usage-rb"
  spec.version = Usage::VERSION
  spec.authors = ["Jeff Dickey @jdx"]
  spec.summary = "Ruby runtime for generated Usage argument parsers"
  spec.homepage = "https://usage.jdx.dev"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "ruby-lsp", "~> 0.26"
  spec.add_development_dependency "standard", "~> 1.56"
end
