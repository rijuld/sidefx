# frozen_string_literal: true

require_relative "lib/sidefx/version"

Gem::Specification.new do |spec|
  spec.name = "sidefx"
  spec.version = Sidefx::VERSION
  spec.authors = ["Rijul Dahiya"]
  spec.summary = "A receipt for everything your Rails code actually did."
  spec.description = "Wrap any block (or request) and get a receipt of its side effects: rows written per table, " \
                     "callbacks fired, jobs enqueued, mail sent, HTTP called, cache changed, broadcasts made, and " \
                     "what a rollback undid. Assert on it in tests to stop surprise side effects in CI."
  spec.homepage = "https://github.com/rijuld/sidefx"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
end
