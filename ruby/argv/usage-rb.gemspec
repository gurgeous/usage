require_relative "lib/usage/version"

Gem::Specification.new do |s|
  s.name = "usage-rb"
  s.version = Usage::VERSION
  s.authors = ["@jdx"]

  s.summary = "`usage` cli arg framework for ruby"
  s.homepage = "https://usage.jdx.dev"
  s.license = "MIT"
  s.required_ruby_version = ">= 3.3"
  s.metadata = {
    "homepage_uri" => s.homepage,
    "rubygems_mfa_required" => "true",
    "source_code_uri" => s.homepage
  }

  # what's in the gem?
  s.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  s.require_paths = ["lib"]
end
