# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "stringio"

require_relative "../lib/http_client"
require_relative "../lib/manifest_directory"
require_relative "../lib/manifest_diff"
require_relative "../lib/project_scaffold"
require_relative "../lib/tools_check"
require_relative "../lib/version"
require_relative "../lib/workspaces_client"
require_relative "../lib/yaml_compat"

load File.expand_path("../../../bin/vatio", __dir__) unless defined?(VatioCLI)

class VatioCliDxTest < Minitest::Test
  CLI_PATH = File.expand_path("../../../bin/vatio", __dir__)
  FakeResponse = Struct.new(:code, :body, :message, :headers) do
    def [](key)
      headers[key]
    end
  end

  def test_yaml_reader_does_not_depend_on_safe_load_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "workspace.yml")
      File.write(path, "slug: girlslab\n")

      assert_equal({ "slug" => "girlslab" }, VatioYamlCompat.load_file(path))
    end
  end

  def test_manifest_loads_with_supported_yaml_and_collection_features
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "tools"))
      File.write(File.join(dir, "workspace.yml"), "slug: girlslab\n")
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help visitors.\n")
      File.write(
        File.join(dir, "tools", "lookup.js"),
        "export const spec = { description: \"Lookup\", parameters: { type: \"object\", properties: {} } };\n" \
        "export default async function lookup() { return { success: true, message: \"ok\" }; }\n"
      )

      manifest = VatioManifestDirectory.load(dir)

      assert_equal "girlslab", manifest.dig("workspace", "slug")
      assert_equal [ "lookup" ], manifest["tools"].map { |tool| tool["key"] }
    end
  end

  def test_tools_check_requires_the_main_agent
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "workspace.yml"), "slug: acme\n")
      File.write(File.join(dir, "agents", "helper.yml"), "key: helper\ninstructions: Help.\n")

      result = VatioToolsCheck.call(dir)

      refute result.ok?
      assert_includes result.errors.join, "agents must include \"main\""
    end
  end

  def test_tools_check_passes_with_the_main_agent
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "workspace.yml"), "slug: acme\n")
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")

      assert VatioToolsCheck.call(dir).ok?
    end
  end

  def test_manifest_loads_yaml_declarative_http_tool_alongside_js
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "tools"))
      File.write(File.join(dir, "workspace.yml"), "slug: girlslab\n")
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help visitors.\n")
      File.write(
        File.join(dir, "tools", "lookup.js"),
        "export const spec = { description: \"Lookup\", parameters: { type: \"object\", properties: {} } };\n" \
        "export default async function lookup() { return { result: \"ok\", message: \"ok\" }; }\n"
      )
      File.write(File.join(dir, "tools", "list_plans.yml"), <<~YAML)
        description: "Lists plans."
        when_to_use: "When asked about plans."
        request:
          method: GET
          base_url: "$env.WAVE_API_BASE"
          path: /api/plans
        respond:
          data:
            plans: "$.data"
      YAML

      manifest = VatioManifestDirectory.load(dir)
      tools = manifest["tools"].to_h { |tool| [ tool["key"], tool ] }

      assert_equal %w[list_plans lookup], tools.keys.sort
      assert_equal "js", tools["lookup"]["kind"]
      assert_equal "http", tools["list_plans"]["kind"]
      assert_equal "Lists plans.", tools["list_plans"]["description"]
    end
  end

  def test_tools_check_validates_yaml_tool_request_shape
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "tools"))
      File.write(File.join(dir, "workspace.yml"), "slug: girlslab\n")
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")
      File.write(File.join(dir, "tools", "broken.yml"), <<~YAML)
        description: "Missing request method"
        request:
          path: /api/plans
      YAML

      result = VatioToolsCheck.call(dir)

      refute result.ok?
      assert_includes result.errors.join, "request.method must be one of"
    end
  end

  def test_manifest_diff_never_contains_source_or_knowledge_bodies
    local = {
      "tools" => [ { "key" => "lookup", "source" => "new secret source" } ],
      "knowledge" => [ { "source" => "plans.md", "body" => "new private body" } ]
    }
    remote = {
      "tools" => [ { "key" => "lookup", "source" => "old secret source" } ],
      "knowledge" => [ { "source" => "plans.md", "body" => "old private body" } ]
    }

    result = VatioManifestDiff.call(local: local, remote: remote)
    serialized = JSON.generate(result)

    refute_includes serialized, "secret source"
    refute_includes serialized, "private body"
    assert_equal %w[knowledge tools], result.map { |change| change["type"] }
  end

  def test_http_errors_preserve_status_and_request_id
    response = FakeResponse.new(
      "404",
      JSON.generate(error: "workspace_not_found", error_description: "Workspace missing", request_id: "req-123"),
      "Not Found",
      {}
    )

    error = assert_raises(VatioHttpClient::NotFoundError) do
      VatioHttpClient.allocate.send(:parse_response, response)
    end

    assert_equal 404, error.status
    assert_equal "req-123", error.request_id
    assert_equal "Workspace missing", error.message
  end

  def test_html_server_error_uses_header_request_id_without_dumping_html
    response = FakeResponse.new("500", "<html>internal failure</html>", "Internal Server Error", { "X-Request-Id" => "req-500" })

    error = assert_raises(VatioHttpClient::Error) do
      VatioHttpClient.allocate.send(:parse_response, response)
    end

    assert_equal 500, error.status
    assert_equal "req-500", error.request_id
    assert_equal "HTTP 500: Internal Server Error", error.message
    refute_includes error.message, "<html>"
  end

  def test_workspace_creation_writes_only_workspace_yml
    Dir.mktmpdir do |dir|
      workspace = VatioProjectScaffold.new.create_workspace!(dir, slug: "girlslab")
      files = Dir.glob(workspace.join("**", "*"), File::FNM_DOTMATCH).reject { |path| File.directory?(path) }

      assert_equal [ workspace.join("workspace.yml").to_s ], files
    end
  end

  def test_version_declares_supported_ruby_range
    assert_operator VatioCliVersion::MINIMUM_RUBY, :<=, Gem::Version.new("3.2.0")
    assert VatioCliVersion.ruby_supported?
  end

  def test_remote_creation_is_idempotent
    fake_client = Object.new
    fake_client.define_singleton_method(:exists?) { |slug| slug == "existing" }
    fake_client.define_singleton_method(:create) { |slug:, name:| { "slug" => slug, "name" => name } }
    cli = VatioCLI.new
    cli.define_singleton_method(:workspaces_client) { fake_client }

    assert_equal :existing, cli.send(:ensure_remote_workspace_for_push!, "existing")
    assert_equal :created, cli.send(:ensure_remote_workspace_for_push!, "new", name: "New")
  end

  def test_doctor_reports_runtime_without_printing_token
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".vatio"))
      File.write(
        File.join(dir, ".vatio", "config.json"),
        JSON.generate(token: "vat_super_secret", base_url: "https://vatio.example")
      )

      stdout, stderr, status = Open3.capture3(CLI_PATH, "doctor", chdir: dir)

      assert status.success?, stderr
      assert_includes stdout, "Ruby executable:"
      assert_includes stdout, "Psych"
      assert_includes stdout, "Token: configured"
      assert_includes stdout, "Docs: https://vatio.ai/docs"
      refute_includes stdout, "vat_super_secret"
    end
  end

  def test_update_points_to_docs_instead_of_installing_skills
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".vatio"))
      File.write(File.join(dir, ".vatio", "config.json"), JSON.generate(token: "vat_x", base_url: "https://vatio.example"))

      stdout, stderr, status = Open3.capture3(CLI_PATH, "update", chdir: dir)

      assert status.success?, stderr
      assert_includes stdout, "https://vatio.ai/docs"
      refute_includes stdout, "skill added"
    end
  end

  def test_config_set_assistants_is_a_removed_key
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".vatio"))
      File.write(File.join(dir, ".vatio", "config.json"), JSON.generate(token: "vat_x"))

      _stdout, stderr, status = Open3.capture3(CLI_PATH, "config", "set", "assistants", "cursor", chdir: dir)

      refute status.success?
      assert_match(/assistants.*removed/i, stderr)
    end
  end

  private

  def directory_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).to_h do |path|
      [ path.delete_prefix("#{root}/"), File.directory?(path) ? :directory : File.binread(path) ]
    end
  end
end
