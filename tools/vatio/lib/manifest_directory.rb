# frozen_string_literal: true

require "yaml"
require "pathname"
require_relative "tool_spec_parser"
require_relative "yaml_compat"

# Pure-Ruby directory → manifest hash (no Rails). Source of truth for vatio.
# Keep backend/lib/vatio/manifest_directory.rb in sync (ManifestLoader / Docker).
module VatioManifestDirectory
  module_function

  def load(path)
    root = Pathname(path)
    raise ArgumentError, "manifest directory not found: #{root}" unless root.directory?

    workspace = load_yaml(root.join("workspace.yml")) || {}
    agents = {}
    Dir.glob(root.join("agents", "*.yml")).each do |file|
      data = load_yaml(file) || {}
      key = data["key"].to_s.strip
      key = File.basename(file, ".*") if key.empty?
      agents[key] = data
    end

    knowledge = []
    Dir.glob(root.join("knowledge", "*.md")).sort.each do |file|
      knowledge << knowledge_entry_from_markdown(file)
    end

    tools = VatioToolSpecParser.load_tools_from_directory(root)
    auth_providers = VatioToolSpecParser.load_auth_providers_from_directory(root)
    libs = VatioToolSpecParser.load_libs_from_directory(root)
    authentication = workspace.delete("authentication") || {}

    {
      "workspace" => workspace,
      "agents" => agents,
      "knowledge" => knowledge,
      "tools" => tools,
      "auth_providers" => auth_providers,
      "libs" => libs,
      "authentication" => authentication
    }
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
  private_class_method :load_yaml, :knowledge_entry_from_markdown
end
