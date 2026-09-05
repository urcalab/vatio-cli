# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"
require "rubygems/version"
require_relative "version"

# Resolves the latest published vatio-cli release and remembers the answer for
# a day. install.sh pins each install to a release tag, so both `vatio update`
# and the passive "new release" notice ask GitHub what that tag is — at most
# once per day, and never in a way that can fail a command.
module VatioReleaseCheck
  REPO = "urcalab/vatio-cli"
  LATEST_RELEASE_URL = "https://api.github.com/repos/#{REPO}/releases/latest"
  INSTALL_SCRIPT_URL = "https://raw.githubusercontent.com/#{REPO}/main/install.sh"
  CACHE_TTL = 86_400
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 3

  module_function

  def install_command
    "curl -fsSL #{INSTALL_SCRIPT_URL} | bash"
  end

  # True when the CLI runs from a git clone (contributors) instead of from an
  # install.sh tarball — there `git pull` owns updates, not the installer.
  def source_checkout?(root)
    File.directory?(File.join(root, ".git"))
  end

  # Mirrors install.sh's INSTALL_DIR so the cache lands beside the installs.
  def home
    configured = ENV["VATIO_CLI_HOME"].to_s.strip
    configured.empty? ? File.join(Dir.home, ".vatio-cli") : configured
  end

  def cache_path
    File.join(home, "release-check.json")
  end

  def disabled?
    return true unless ENV["VATIO_CLI_NO_UPDATE_CHECK"].to_s.strip.empty?
    return true unless ENV["CI"].to_s.strip.empty?

    false
  end

  def newer?(current:, latest:)
    return false if latest.to_s.strip.empty?

    Gem::Version.new(strip_prefix(latest)) > Gem::Version.new(strip_prefix(current))
  rescue ArgumentError
    false
  end

  def strip_prefix(tag)
    tag.to_s.strip.sub(/\Av/, "")
  end

  # Uncached lookup. Returns a tag ("v0.3.0"), or nil on any failure — an
  # unreachable GitHub must never turn into a broken CLI.
  def latest_tag
    uri = URI.parse(LATEST_RELEASE_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/vnd.github+json"
    request["User-Agent"] = "vatio-cli/#{VatioCliVersion::VERSION}"

    response = http.request(request)
    return nil unless response.code.to_i == 200

    tag = JSON.parse(response.body.to_s)["tag_name"].to_s.strip
    tag.empty? ? nil : tag
  rescue StandardError
    nil
  end

  # Cached lookup for the passive notice. A failed lookup is cached too, so an
  # offline developer pays the timeout once a day rather than once a command.
  def cached_latest_tag(now: Time.now)
    cached = read_cache
    return cached["tag"] if cached && now.to_i - cached["checked_at"].to_i < CACHE_TTL

    tag = latest_tag
    write_cache(tag: tag, now: now)
    tag
  end

  def read_cache
    data = JSON.parse(File.read(cache_path))
    data.is_a?(Hash) && data.key?("checked_at") ? data : nil
  rescue StandardError
    nil
  end

  def write_cache(tag:, now: Time.now)
    FileUtils.mkdir_p(File.dirname(cache_path))
    File.write(cache_path, JSON.generate("checked_at" => now.to_i, "tag" => tag))
    tag
  rescue StandardError
    nil
  end

  def clear_cache!
    File.delete(cache_path) if File.file?(cache_path)
    nil
  rescue StandardError
    nil
  end

  # Re-runs the published installer, which unpacks the tag into
  # ~/.vatio-cli/<tag> and repoints the `current` symlink at it.
  def install!(tag: nil)
    requested = tag.to_s.strip
    env = requested.empty? ? {} : { "VATIO_CLI_VERSION" => requested }
    system(env, "bash", "-c", "set -o pipefail; #{install_command}")
  end
end
