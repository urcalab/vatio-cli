# frozen_string_literal: true

require "json"
require "yaml"
require "pathname"
require_relative "tool_spec_parser"
require_relative "manifest_directory"

# Static contract checks for workspace JS tools (CLI-side, no Rails).
# Runs on `vatio tools check` and before `vatio push`.
module VatioToolsCheck
  # Platform tools the CLI knows about (keep in sync with Vatio::Catalog::ToolCatalog).
  PLATFORM_TOOL_KEYS = %w[
    knowledge_lookup
    identify_contact
  ].freeze

  # A workspace has exactly one agent and it is the conversation entry point.
  ENTRY_AGENT = "main"

  Result = Struct.new(:errors, :warnings, keyword_init: true) do
    def ok?
      errors.empty?
    end
  end

  module_function

  def call(root)
    root = Pathname(root)
    errors = []
    warnings = []

    begin
      manifest = VatioManifestDirectory.load(root)
    rescue ArgumentError => e
      return Result.new(errors: [ e.message ], warnings: [])
    end

    tools = Array(manifest["tools"])
    tool_keys = tools.map { |row| row["key"].to_s }
    auth_schemes = extract_auth_schemes(manifest)
    auth_provider_keys = Array(manifest["auth_providers"]).map { |row| row["key"].to_s }

    Dir.glob(root.join("tools", "*.js")).sort.each do |path|
      validate_tool_file!(path, errors, warnings)
    end

    Dir.glob(root.join("tools", "*.{yml,yaml}")).sort.each do |path|
      validate_yaml_tool_file!(path, errors, warnings)
    end

    Dir.glob(root.join("lib", "*.js")).sort.each do |path|
      validate_lib_file!(path, errors)
    end

    tools.each do |tool|
      validate_loaded_tool!(tool, auth_schemes, errors, warnings)
    end

    validate_agent_tool_refs!(manifest["agents"] || {}, tool_keys, errors, warnings)
    validate_auth_scheme_providers!(auth_schemes, auth_provider_keys, errors)
    validate_entry_agent!(manifest["agents"] || {}, errors)

    Result.new(errors: errors, warnings: warnings)
  end

  def validate_lib_file!(path, errors)
    key = File.basename(path, ".js")
    source = File.read(path)
    label = "lib/#{File.basename(path)}"

    unless key.match?(VatioToolSpecParser::KEY_FORMAT)
      errors << "#{label}: invalid key #{key.inspect} (use lowercase letters, digits, - or _)"
    end
    if source.strip.empty?
      errors << "#{label}: file is empty"
    end
    if source.match?(/export\s+const\s+spec\s*=/)
      errors << "#{label}: looks like a tool (export const spec) — move to tools/"
    end
  end
  private_class_method :validate_lib_file!

  def validate_tool_file!(path, errors, warnings)
    key = File.basename(path, ".js")
    source = File.read(path)
    label = "tools/#{File.basename(path)}"

    unless key.match?(VatioToolSpecParser::KEY_FORMAT)
      errors << "#{label}: invalid key #{key.inspect} (use lowercase letters, digits, - or _)"
    end

    begin
      raw_spec = VatioToolSpecParser.parse_spec(source, file: path)
    rescue ArgumentError => e
      errors << "#{label}: #{e.message}"
      return
    end

    if raw_spec.key?("requires_member")
      errors << "#{label}: requires_member is removed — use access: \"<scheme>\" or omit for public"
    end

    description = raw_spec["description"].to_s.strip
    errors << "#{label}: spec.description is required" if description.empty?

    when_to_use = raw_spec["when_to_use"].to_s.strip
    warnings << "#{label}: spec.when_to_use is empty (falls back to description)" if when_to_use.empty?

    parameters = raw_spec["parameters"]
    if parameters.nil?
      warnings << "#{label}: spec.parameters missing (defaulting to {})"
    elsif !parameters.is_a?(Hash)
      errors << "#{label}: spec.parameters must be an object"
    else
      type = parameters["type"].to_s
      if !type.empty? && type != "object"
        errors << "#{label}: spec.parameters.type must be \"object\" (got #{type.inspect})"
      end
      if parameters.key?("properties") && !parameters["properties"].is_a?(Hash)
        errors << "#{label}: spec.parameters.properties must be an object"
      end
      if parameters.key?("required") && !parameters["required"].is_a?(Array)
        errors << "#{label}: spec.parameters.required must be an array"
      end
    end

    validate_raw_access!(label, raw_spec["access"], errors)

    unless source.match?(/^\s*export\s+default\b/m)
      errors << "#{label}: missing export default handler"
    end

    validate_result_contract!(label, source, errors)
  end
  private_class_method :validate_tool_file!

  HTTP_METHODS = %w[GET POST PATCH DELETE].freeze

  # tools/*.yml — declarative single HTTP call (kind: "http"). No JS parsing:
  # just the shape Vatio::Tools::WorkspaceHttpTool expects at runtime.
  def validate_yaml_tool_file!(path, errors, warnings)
    key = File.basename(path, ".*")
    label = "tools/#{File.basename(path)}"

    unless key.match?(VatioToolSpecParser::KEY_FORMAT)
      errors << "#{label}: invalid key #{key.inspect} (use lowercase letters, digits, - or _)"
    end

    begin
      spec = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false, filename: path.to_s) || {}
    rescue Psych::SyntaxError => e
      errors << "#{label}: invalid YAML (#{e.message})"
      return
    end

    description = spec["description"].to_s.strip
    errors << "#{label}: description is required" if description.empty?

    when_to_use = spec["when_to_use"].to_s.strip
    warnings << "#{label}: when_to_use is empty (falls back to description)" if when_to_use.empty?

    validate_raw_access!(label, spec["access"], errors)

    request = spec["request"]
    unless request.is_a?(Hash)
      errors << "#{label}: request: is required"
      return
    end

    method = request["method"].to_s.upcase
    unless HTTP_METHODS.include?(method)
      errors << "#{label}: request.method must be one of #{HTTP_METHODS.join(', ')} (got #{request["method"].inspect})"
    end

    errors << "#{label}: request.path is required" if request["path"].to_s.strip.empty?

    respond = spec["respond"]
    errors << "#{label}: respond must be an object" if respond && !respond.is_a?(Hash)
  end
  private_class_method :validate_yaml_tool_file!

  # The tool result contract is { result: "ok" | "error", message }. `success` was
  # removed because it conflated "the call worked" with "the answer is affirmative":
  # a query that ran fine and found nothing is "ok", not a failure.
  def validate_result_contract!(label, source, errors)
    if source.match?(/\bsuccess\s*:/)
      errors << "#{label}: `success:` was replaced by `result: \"ok\" | \"error\"` " \
                "(a negative answer that ran fine is \"ok\"). See https://vatio.ai/docs"
    end

    statuses = source.scan(/\bresult\s*:\s*["']([a-z_]+)["']/).flatten.uniq
    unknown = statuses - %w[ok error]
    if unknown.any?
      errors << "#{label}: invalid result #{unknown.map(&:inspect).join(", ")} (use \"ok\" or \"error\")"
    end
  end
  private_class_method :validate_result_contract!

  def validate_loaded_tool!(tool, auth_schemes, errors, warnings)
    key = tool["key"].to_s
    label = "tool #{key}"

    if tool["description"].to_s.strip.empty?
      errors << "#{label}: description is blank after load"
    end

    access = tool["access"]
    return unless access.is_a?(Hash)

    scheme = access["scheme"].to_s
    return if scheme.empty?

    unless auth_schemes.key?(scheme)
      errors << "#{label}: access #{scheme.inspect} is not declared in workspace.yml authentication.schemes"
    end

    properties = tool.dig("parameters", "properties")
    if properties.is_a?(Hash) && properties.key?("user_id")
      warnings << "#{label}: protected tool declares public user_id — use ctx.auth.subject instead"
    end
  end
  private_class_method :validate_loaded_tool!

  def validate_raw_access!(label, raw, errors)
    case raw
    when nil, "public"
      nil
    when String
      scheme = raw.strip
      unless scheme.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
        errors << "#{label}: access must be \"public\" or a scheme name (got #{raw.inspect})"
      end
    when Hash
      errors << "#{label}: access must be a string (\"public\" or scheme name); object form and scopes are not supported"
    else
      errors << "#{label}: access must be omitted, \"public\", or a scheme name"
    end
  end
  private_class_method :validate_raw_access!

  def validate_agent_tool_refs!(agents, workspace_tool_keys, errors, warnings)
    known = (PLATFORM_TOOL_KEYS + workspace_tool_keys).uniq

    agents.each do |agent_key, data|
      Array(data["tools"]).each do |entry|
        tool_key = entry.is_a?(Hash) ? entry["key"].to_s : entry.to_s
        next if tool_key.empty?

        if VatioToolSpecParser::DEPRECATED_KEYS.include?(tool_key)
          errors << "agent #{agent_key}: tool #{tool_key.inspect} was removed from the platform"
        elsif !known.include?(tool_key)
          warnings << "agent #{agent_key}: unknown tool #{tool_key.inspect} (not in tools/ or platform catalog)"
        end
      end
    end
  end
  private_class_method :validate_agent_tool_refs!

  # Keep in sync with Vatio::Authentication::Schemes (JS providers only).
  AUTH_PROVIDER_JS_FORMAT = /\Aauth\/[a-z0-9]+(?:[-_][a-z0-9]+)*\.js\z/

  # Keep in sync with ChannelIdentity::CHANNELS (CLI has no Rails/DB access).
  KNOWN_CHANNELS = %w[web whatsapp email instagram sandbox cli].freeze

  def validate_auth_scheme_providers!(schemes, provider_keys, errors)
    schemes.each do |scheme, config|
      provider = config.is_a?(Hash) ? config["provider"].to_s.strip : ""
      next if provider.empty?

      unless provider.match?(AUTH_PROVIDER_JS_FORMAT)
        errors << "authentication.schemes.#{scheme}: provider must be auth/<key>.js"
        next
      end

      key = File.basename(provider, ".js")
      next if provider_keys.include?(key)

      errors << "authentication.schemes.#{scheme}: provider file auth/#{key}.js is missing"
    end

    schemes.each do |scheme, config|
      next unless config.is_a?(Hash) && config["proactive"]

      channels = Array(config["channels"])
      errors << "authentication.schemes.#{scheme}: proactive requires at least one channel" if channels.empty?
      unknown = channels.map(&:to_s) - KNOWN_CHANNELS
      if unknown.any?
        errors << "authentication.schemes.#{scheme}: channels contains unknown channels: #{unknown.join(", ")}"
      end
    end
  end
  private_class_method :validate_auth_scheme_providers!

  def validate_entry_agent!(agents, errors)
    return if agents.key?(ENTRY_AGENT)

    errors << "agents must include #{ENTRY_AGENT.inspect} (create agents/#{ENTRY_AGENT}.yml)"
  end
  private_class_method :validate_entry_agent!

  def extract_auth_schemes(manifest)
    authentication = manifest["authentication"]
    return {} unless authentication.is_a?(Hash)

    schemes = authentication["schemes"]
    return {} unless schemes.is_a?(Hash)

    schemes.transform_keys(&:to_s)
  end
  private_class_method :extract_auth_schemes
end
