# frozen_string_literal: true

require_relative "tools/vatio/lib/version"

Gem::Specification.new do |spec|
  spec.name = "vatio"
  spec.version = VatioCliVersion::VERSION
  spec.summary = "Vatio CLI — deploy and manage Vatio agent workspaces"
  spec.description = "Command-line client for Vatio (https://vatio.ai), the AI agent " \
                      "platform. Push/publish/rollback workspaces, manage secrets, and " \
                      "chat against preview deployments. Pure Ruby stdlib, no gem deps."
  spec.authors = [ "Vatio" ]
  spec.email = [ "support@vatio.ai" ]
  spec.homepage = "https://vatio.ai"
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= #{VatioCliVersion::MINIMUM_RUBY}"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/urcalab/vatio-cli",
    "documentation_uri" => "https://vatio.ai/docs",
    "bug_tracker_uri" => "https://github.com/urcalab/vatio-cli/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[ "bin/vatio", "tools/vatio/lib/**/*.rb", "README.md", "LICENSE.txt" ]
  spec.bindir = "bin"
  spec.executables = [ "vatio" ]
  spec.require_paths = [ "tools/vatio/lib" ]
end
