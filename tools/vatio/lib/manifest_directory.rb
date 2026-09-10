# frozen_string_literal: true

require "digest"
require "yaml"
require "pathname"
require_relative "tool_spec_parser"
require_relative "yaml_compat"

# Pure-Ruby directory → manifest hash (no Rails). Source of truth for vatio.
# Keep lib/vatio/manifest_directory.rb in urcalab/vatio in sync (ManifestLoader).
module VatioManifestDirectory
  # Only formats Active Storage can turn into a variant — an SVG logo would
  # attach and then fail to render as the widget avatar.
  LOGO_CONTENT_TYPES = {
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }.freeze
  LOGO_MAX_BYTES = 2 * 1024 * 1024
  # Mirrors Vatio::Catalog::AgentKeys::MAIN — a workspace has exactly one agent.
  ENTRY_AGENT = "main"

  module_function

  # The workspace slug is the directory name — there is no file that repeats it.
  # `widget.yml` is the only workspace-level file, and it is optional.
  def load(path)
    root = Pathname(path)
    raise ArgumentError, "manifest directory not found: #{root}" unless root.directory?

    agents = {}
    Dir.glob(root.join("agents", "*.yml")).each do |file|
      data = load_yaml(file) || {}
      key = data["key"].to_s.strip
      key = File.basename(file, ".*") if key.empty?
      agents[key] = data
    end

    business = hoist_business!(agents)

    knowledge = []
    Dir.glob(root.join("knowledge", "*.md")).sort.each do |file|
      knowledge << knowledge_entry_from_markdown(file)
    end
    knowledge_sources = Array(load_yaml(root.join("knowledge", "sources.yml")))

    tools = VatioToolSpecParser.load_tools_from_directory(root)
    auth_providers = VatioToolSpecParser.load_auth_providers_from_directory(root)
    libs = VatioToolSpecParser.load_libs_from_directory(root)

    {
      "business" => business,
      "widget" => widget_from_directory(root),
      "agents" => agents,
      "knowledge" => knowledge,
      "knowledge_sources" => knowledge_sources,
      "tools" => tools,
      "auth_providers" => auth_providers.map { |row| row.slice("key", "source") },
      "libs" => libs,
      "authentication" => { "schemes" => schemes_from_auth_providers(auth_providers) }
    }
  end

  # `business` is authored inside agents/main.yml, next to the instructions it
  # gives context to, but it describes the workspace rather than the agent — so
  # it is hoisted to the root, where the platform also stores it. That keeps
  # `vatio diff` comparing like with like.
  def hoist_business!(agents)
    row = agents[ENTRY_AGENT]
    return {} unless row.is_a?(Hash)

    business = row["business"]
    agents[ENTRY_AGENT] = row.reject { |key, _value| key == "business" }
    business.is_a?(Hash) ? business : {}
  end

  # widget.yml — the public face of the workspace: accent_color, about, logo
  # and the origins allowed to embed the widget. Owned by the manifest, so the
  # Vatio app shows it read-only.
  def widget_from_directory(root)
    widget = load_yaml(Pathname(root).join("widget.yml")) || {}
    widget = widget.merge("logo" => logo_entry(root, widget["logo"]))
    widget.compact
  end

  # The bytes ride along in the push payload; the platform attaches them and
  # strips them back out before the revision is stored, so a stored manifest
  # never carries an image.
  def logo_entry(root, value)
    relative = value.to_s.strip
    return nil if relative.empty?

    if relative.start_with?("/") || relative.split("/").include?("..")
      raise ArgumentError, "widget.logo must be a file inside the workspace (got #{relative.inspect})"
    end

    file = Pathname(root).join(relative)
    raise ArgumentError, "widget.logo not found: #{relative}" unless file.file?

    content_type = LOGO_CONTENT_TYPES[file.extname.downcase]
    unless content_type
      raise ArgumentError,
        "widget.logo must be one of #{LOGO_CONTENT_TYPES.keys.join(", ")} (got #{file.extname})"
    end

    bytes = file.binread
    if bytes.bytesize > LOGO_MAX_BYTES
      raise ArgumentError, "widget.logo is #{bytes.bytesize} bytes; the limit is #{LOGO_MAX_BYTES}"
    end

    {
      "filename" => file.basename.to_s,
      "content_type" => content_type,
      "digest" => Digest::SHA256.hexdigest(bytes),
      # pack("m0") is strict base64 without the base64 library, which stopped
      # being a default gem in Ruby 3.4 — this CLI stays dependency-free.
      "content_base64" => [ bytes ].pack("m0")
    }
  end

  # One scheme per auth/*.js: the filename is the scheme name and the file's
  # optional spec carries its options, so nothing has to name the provider path.
  def schemes_from_auth_providers(providers)
    providers.each_with_object({}) do |row, memo|
      spec = row["spec"].is_a?(Hash) ? row["spec"] : {}
      memo[row["key"]] = {
        "profile_authoritative" => spec["profile_authoritative"] == true,
        "proactive" => spec["proactive"] == true,
        "channels" => Array(spec["channels"]).map(&:to_s)
      }
    end
  end

  def load_yaml(path)
    return nil unless File.file?(path)

    VatioYamlCompat.load_file(path)
  end

  def knowledge_entry_from_markdown(path)
    content = File.read(path)
    title = nil
    body_lines = []
    content.each_line do |line|
      if title.nil? && line.start_with?("# ")
        title = line.delete_prefix("# ").strip
        next
      end
      body_lines << line
    end
    title ||= File.basename(path, ".*").tr("-_", " ").split.map(&:capitalize).join(" ")
    body = body_lines.join.strip
    body = content.strip if body.empty?
    {
      "title" => title,
      "body" => body,
      "source" => File.basename(path)
    }
  end
  private_class_method :load_yaml, :knowledge_entry_from_markdown, :logo_entry,
    :widget_from_directory, :schemes_from_auth_providers, :hoist_business!
end
