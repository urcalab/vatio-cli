# frozen_string_literal: true

require "open3"
require "rbconfig"
require "rubygems/version"

module VatioCliVersion
  VERSION = "0.2.0"
  MINIMUM_RUBY = Gem::Version.new("2.6.0")

  module_function

  def build(root)
    configured = ENV["VATIO_CLI_BUILD"].to_s.strip
    return configured unless configured.empty?

    # capture3, not capture2: a tarball install has no .git, and git's
    # "fatal: not a git repository" must not leak into `vatio version`.
    stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--short=12", "HEAD", chdir: root)
    status.success? ? stdout.strip : "unknown"
  rescue SystemCallError
    "unknown"
  end

  def ruby_supported?
    Gem::Version.new(RUBY_VERSION) >= MINIMUM_RUBY
  end

  def platform
    RbConfig::CONFIG["host"]
  end
end
