# frozen_string_literal: true

require "json"
require "yaml"

# Keep in sync with tools/vatio/lib/tool_spec_parser.rb
module VatioToolSpecParser
  KEY_FORMAT = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/
  DEPRECATED_KEYS = %w[complete_mission claim_email verify_email_claim start_authentication verify_authentication].freeze

  module_function

  # tools/*.js — full JS logic, runs sandboxed via JsRuntime (kind: "js").
  # tools/*.yml — declarative single HTTP call, runs natively, no sandbox
  # round-trip (kind: "http"). See Vatio::Tools::WorkspaceHttpTool for the spec.
  def load_tools_from_directory(root)
    path = Pathname(root)
    tools_dir = path.join("tools")
    return [] unless tools_dir.directory?

    js = Dir.glob(tools_dir.join("*.js")).sort.map { |file| load_tool_file(file) }.compact
    yml = Dir.glob(tools_dir.join("*.{yml,yaml}")).sort.map { |file| load_yaml_tool_file(file) }.compact
    (js + yml).sort_by { |row| row["key"] }
  end

  def load_auth_providers_from_directory(root)
    path = Pathname(root)
    auth_dir = path.join("auth")
    return [] unless auth_dir.directory?

    Dir.glob(auth_dir.join("*.js")).sort.each_with_object([]) do |file, providers|
      key = File.basename(file, ".js")
      next unless key.match?(KEY_FORMAT)

      providers << {
        "key" => key,
        "source" => File.read(file)
      }
    end
  end

  # Shared JS helpers under lib/*.js (concatenated once into the tools worker bundle).
  # Not tools — no export const spec. Plain functions in shared scope.
  def load_libs_from_directory(root)
    path = Pathname(root)
    lib_dir = path.join("lib")
    return [] unless lib_dir.directory?

    Dir.glob(lib_dir.join("*.js")).sort.each_with_object([]) do |file, libs|
      key = File.basename(file, ".js")
      next unless key.match?(KEY_FORMAT)

      libs << {
        "key" => key,
        "source" => File.read(file)
      }
    end
  end

  def load_tool_file(path)
    source = File.read(path)
    key = File.basename(path, ".js")
    spec = parse_spec(source, file: path)
    # Wire form stays a string / omitted — server normalize_access is not yet
    # idempotent on the stored {"scheme"=>…} hash shape.
    access = wire_access(spec["access"])

    {
      "key" => key,
      "name" => spec.fetch("name", key.tr("_-", " ").split.map(&:capitalize).join(" ")),
      "description" => spec.fetch("description", "").to_s,
      "when_to_use" => spec.fetch("when_to_use", spec["description"]).to_s,
      "parameters" => spec["parameters"].is_a?(Hash) ? spec["parameters"] : {},
      "access" => access,
      "source" => source,
      "kind" => "js"
    }.tap { |row| row.delete("access") if access.nil? }
  end

  # tools/*.yml: {description, when_to_use, parameters, access, request:, respond:}.
  # `source` keeps the whole file — Vatio::Tools::WorkspaceHttpTool reads the
  # request:/respond: keys back out of it at call time.
  def load_yaml_tool_file(path)
    source = File.read(path)
    key = File.basename(path, ".*")
    spec = YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false, filename: path.to_s) || {}
    raise ArgumentError, "missing request: in #{path}" unless spec["request"].is_a?(Hash)

    access = wire_access(spec["access"])

    {
      "key" => key,
      "name" => spec.fetch("name", key.tr("_-", " ").split.map(&:capitalize).join(" ")),
      "description" => spec.fetch("description", "").to_s,
      "when_to_use" => spec.fetch("when_to_use", spec["description"]).to_s,
      "parameters" => spec["parameters"].is_a?(Hash) ? spec["parameters"] : {},
      "access" => access,
      "source" => source,
      "kind" => "http"
    }.tap { |row| row.delete("access") if access.nil? }
  end

  # Authoring form → API wire string (or nil for public).
  def wire_access(raw)
    normalized = normalize_access(raw)
    scheme = normalized["scheme"].to_s
    scheme.empty? ? nil : scheme
  end

  # MVP access: omit / "public" / "<scheme>". Stored as {} or {"scheme" => "<name>"}.
  # Accepts the canonical wire/hash form too (idempotent for push + reload).
  def normalize_access(raw)
    case raw
    when nil, "public"
      {}
    when String
      scheme = raw.strip
      return {} if scheme.empty? || scheme == "public"
      raise ArgumentError, "access must be \"public\" or a scheme name" unless scheme.match?(/\A[a-z][a-z0-9_]{0,63}\z/)

      { "scheme" => scheme }
    when Hash
      return {} if raw.empty?

      stringified = raw.transform_keys(&:to_s)
      if stringified.keys == [ "scheme" ]
        return normalize_access(stringified["scheme"])
      end

      raise ArgumentError,
        "access must be a string (\"public\" or scheme name); object form and scopes are not supported"
    else
      raise ArgumentError, "access must be omitted, \"public\", or a scheme name"
    end
  end

  def parse_spec(source, file: nil)
    match = source.match(/export\s+const\s+spec\s*=\s*/m)
    raise ArgumentError, "missing export const spec in #{file}" unless match

    start = match.end(0)
    literal = extract_braced_object(source, start)
    parse_object_literal(literal)
  rescue JSON::ParserError => e
    label = file || "tool"
    raise ArgumentError, "invalid spec object in #{label}: #{e.message}"
  end

  def parse_object_literal(literal)
    JSON.parse(literal)
  rescue JSON::ParserError
    JSON.parse(js_object_to_json(literal))
  end

  def js_object_to_json(source)
    out = +""
    i = 0
    n = source.length
    while i < n
      i = skip_js_trivia(source, i)
      break if i >= n

      char = source[i]
      if char == "'" || char == '"' || char == "`"
        encoded, i = read_js_string(source, i)
        out << encoded
        next
      end

      if char == ","
        j = skip_js_trivia(source, i + 1)
        if j < n && (source[j] == "}" || source[j] == "]")
          i = j
          next
        end
        out << ","
        i += 1
        next
      end

      if char.match?(/[A-Za-z_$]/)
        ident, i = read_js_identifier(source, i)
        j = skip_js_trivia(source, i)
        if j < n && source[j] == ":"
          out << JSON.generate(ident)
        elsif %w[true false null].include?(ident)
          out << ident
        else
          raise JSON::ParserError, "unsupported identifier #{ident.inspect}"
        end
        next
      end

      out << char
      i += 1
    end
    out
  end

  def skip_js_trivia(source, i)
    n = source.length
    loop do
      i += 1 while i < n && source[i] =~ /\s/
      if i + 1 < n && source[i] == "/" && source[i + 1] == "/"
        i += 2
        i += 1 while i < n && source[i] != "\n"
        next
      end
      if i + 1 < n && source[i] == "/" && source[i + 1] == "*"
        close = source.index("*/", i + 2)
        raise JSON::ParserError, "unclosed comment" unless close

        i = close + 2
        next
      end
      return i
    end
  end

  def read_js_identifier(source, start)
    i = start + 1
    i += 1 while i < source.length && source[i].match?(/[A-Za-z0-9_$]/)
    [ source[start...i], i ]
  end

  def read_js_string(source, start)
    quote = source[start]
    i = start + 1
    chars = +""
    escape = false
    while i < source.length
      char = source[i]
      if escape
        chars << decode_js_escape(char)
        escape = false
        i += 1
        next
      end
      if char == "\\"
        escape = true
        i += 1
        next
      end
      if char == quote
        return [ JSON.generate(chars), i + 1 ]
      end
      if quote != "`" && char == "\n"
        raise JSON::ParserError, "unclosed string"
      end
      if quote == "`" && char == "$" && source[i + 1] == "{"
        raise JSON::ParserError, "template interpolation is not supported in spec"
      end

      chars << char
      i += 1
    end
    raise JSON::ParserError, "unclosed string"
  end

  def decode_js_escape(char)
    case char
    when "n" then "\n"
    when "t" then "\t"
    when "r" then "\r"
    when "b" then "\b"
    when "f" then "\f"
    else char
    end
  end

  def extract_braced_object(source, start_index)
    i = start_index
    i += 1 while i < source.length && source[i] =~ /\s/
    raise ArgumentError, "spec must be an object literal" unless source[i] == "{"

    depth = 0
    in_string = false
    string_quote = nil
    escape = false

    (i...source.length).each do |idx|
      char = source[idx]

      if in_string
        if escape
          escape = false
        elsif char == "\\"
          escape = true
        elsif char == string_quote
          in_string = false
          string_quote = nil
        end
        next
      end

      case char
      when "'", '"', "`"
        in_string = true
        string_quote = char
      when "{"
        depth += 1
      when "}"
        depth -= 1
        if depth.zero?
          return source[start_index..idx]
        end
      end
    end

    raise ArgumentError, "unclosed spec object"
  end
end
