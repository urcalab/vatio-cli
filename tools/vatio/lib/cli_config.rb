# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require_relative "yaml_compat"

# Local-only CLI settings for Vatio under .vatio/ at the developer root.
# This file contains credentials and must never be committed.
#
# Developer root = directory with .vatio/config.json and no workspace.yml at same level.
# Workspace root = directory with workspace.yml under the developer root.
#
# Token and base_url live only in developer root config.
# Workspace slug comes from workspace.yml at the workspace root (cwd-based).
#
class VatioCliConfig
  KEYS = %w[base_url token channel from].freeze
  DEFAULT_BASE_URL = "https://vatio.ai"
  REMOVED_KEYS = %w[as].freeze

  class Error < StandardError; end

  def initialize(start_dir: Dir.pwd)
    @start_dir = Pathname(start_dir).expand_path
    @developer_root = find_developer_root(@start_dir)
    @workspace_root = find_workspace_root(@start_dir)
    @config_path = (@developer_root || @start_dir).join(".vatio", "config.json")
    @legacy_as_removed = false
  end

  attr_reader :config_path, :developer_root, :workspace_root, :legacy_as_removed

  def developer_root!
    @developer_root || raise(Error, <<~MSG.chomp)
      Not inside a Vatio developer root (.vatio/config.json not found walking up from #{@start_dir}).
      Run `vatio init` in your agents folder first.
    MSG
  end

  def workspace_root!
    @workspace_root || raise(Error, <<~MSG.chomp)
      Not inside a Vatio workspace (no workspace.yml found under #{@start_dir}).
      Run `vatio new workspace SLUG` from the developer root, then cd into the workspace folder.
    MSG
  end

  def load
    return {} unless @config_path.file?

    data = JSON.parse(@config_path.read)
    data.is_a?(Hash) ? migrate_legacy!(data) : {}
  rescue JSON::ParserError
    {}
  end

  def save(data)
    FileUtils.mkdir_p(@config_path.dirname)
    @config_path.write(JSON.pretty_generate(data) + "\n")
    @config_path.chmod(0o600)
    data
  end

  def get(key)
    key = normalize_key!(key.to_s.strip)
    presence(load[key])
  end

  def set(key, value)
    key = normalize_key!(key.to_s.strip)
    cleaned = value.to_s.strip
    raise Error, "#{key} cannot be empty" if cleaned.empty?

    data = load
    data[key] = cleaned
    save(data)
    cleaned
  end

  def unset(key)
    key = normalize_key!(key.to_s.strip)
    data = load
    data.delete(key)
    save(data)
    nil
  end

  def resolve_base_url
    presence(ENV["VATIO_BASE_URL"])&.delete_suffix("/") ||
      presence(load["base_url"])&.delete_suffix("/") ||
      DEFAULT_BASE_URL
  end

  def resolve_workspace(explicit: nil)
    slug = presence(explicit)&.downcase
    return slug if slug

    slug = presence(ENV["VATIO_WORKSPACE"])&.downcase
    return slug if slug

    slug_from_workspace_yml
  end

  def resolve_token
    presence(ENV["VATIO_TOKEN"]) || presence(load["token"])
  end

  def resolve_channel(explicit: nil)
    presence(explicit) || presence(load["channel"]) || "cli"
  end

  def resolve_from(explicit: nil)
    # Explicit empty string is not used; nil means fall back to config.
    return presence(explicit) unless explicit.nil?

    presence(load["from"])
  end

  def resolve_sandbox_url(explicit: nil, workspace: nil)
    url = presence(explicit) || presence(ENV["VATIO_SANDBOX_URL"])
    return url.delete_suffix("/") if url

    base = resolve_base_url
    ws = workspace || resolve_workspace
    return nil if blank?(base) || blank?(ws)

    "#{base}/api/v1/#{ws}"
  end

  def display_hash
    data = load
    out = {}
    out["base_url"] = resolve_base_url if resolve_base_url
    out["token"] = mask_secret(resolve_token) if resolve_token
    out["channel"] = data["channel"] if presence(data["channel"])
    out["from"] = data["from"] if presence(data["from"])
    out
  end

  def write_auth!(base_url:, token:)
    data = load
    data["base_url"] = base_url.to_s.delete_suffix("/")
    data["token"] = token.to_s
    data.delete("workspace")
    save(data)
  end

  def clear_token!
    data = load
    data.delete("token")
    save(data)
  end

  def local_workspace_slugs
    return [] unless @developer_root

    @developer_root.children.each_with_object([]) do |entry, slugs|
      next unless entry.directory?
      next unless entry.join("workspace.yml").file?

      slug = slug_from_path(entry.join("workspace.yml"))
      slugs << slug if slug
    end.sort
  end

  private

  def migrate_legacy!(data)
    if data.key?("as")
      data.delete("as")
      @legacy_as_removed = true
      save(data)
    end
    data
  end

  def find_developer_root(start)
    current = start
    loop do
      config = current.join(".vatio", "config.json")
      return current if config.file? && !current.join("workspace.yml").file?

      parent = current.parent
      break if parent == current

      current = parent
    end
    nil
  end

  def find_workspace_root(start)
    dev_root = @developer_root
    current = start
    loop do
      if current.join("workspace.yml").file?
        return current if dev_root.nil? || current.to_s.start_with?(dev_root.to_s)
      end

      parent = current.parent
      break if parent == current

      current = parent
    end
    nil
  end

  def slug_from_workspace_yml
    root = @workspace_root
    return nil unless root

    slug_from_path(root.join("workspace.yml"))
  end

  def slug_from_path(path)
    return nil unless path.file?

    data = VatioYamlCompat.load_file(path)
    presence(data["slug"])&.downcase
  rescue Psych::SyntaxError
    nil
  end

  def normalize_key!(key)
    normalized = key.to_s.strip
    if normalized == "assistants"
      raise Error, "config key \"assistants\" was removed — Vatio no longer installs local skills; see https://vatio.ai/docs"
    end
    if REMOVED_KEYS.include?(normalized)
      raise Error, "config key #{normalized.inspect} was removed — use channel and from instead"
    end
    raise Error, "unknown key #{key.inspect} (allowed: #{KEYS.join(", ")})" unless KEYS.include?(normalized)

    normalized
  end

  def mask_secret(value)
    return nil if blank?(value)
    return value if value.length <= 8

    "#{value[0, 4]}…#{value[-4, 4]}"
  end

  def presence(value)
    str = value.to_s.strip
    str.empty? ? nil : str
  end

  def blank?(value)
    presence(value).nil?
  end
end
