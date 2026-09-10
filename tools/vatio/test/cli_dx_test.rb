# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "open3"
require "tmpdir"
require "stringio"

require_relative "../lib/http_client"
require_relative "../lib/manifest_directory"
require_relative "../lib/manifest_diff"
require_relative "../lib/project_scaffold"
require_relative "../lib/release_check"
require_relative "../lib/tools_check"
require_relative "../lib/version"
require_relative "../lib/workspaces_client"
require_relative "../lib/yaml_compat"

load File.expand_path("../../../bin/vatio", __dir__) unless defined?(VatioCLI)

class VatioCliDxTest < Minitest::Test
  CLI_PATH = File.expand_path("../../../bin/vatio", __dir__)
  # Smallest valid PNG — enough to exercise widget.yml's logo handling.
  ONE_PIXEL_PNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF+ndrWAAAAAElFTkSuQmCC"
    .unpack1("m").freeze
  FakeResponse = Struct.new(:code, :body, :message, :headers) do
    def [](key)
      headers[key]
    end
  end

  def test_yaml_reader_does_not_depend_on_safe_load_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "widget.yml")
      File.write(path, "accent_color: \"#3355FF\"\n")

      assert_equal({ "accent_color" => "#3355FF" }, VatioYamlCompat.load_file(path))
    end
  end

  def test_manifest_loads_with_supported_yaml_and_collection_features
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "tools"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help visitors.\n")
      File.write(
        File.join(dir, "tools", "lookup.js"),
        "export const spec = { description: \"Lookup\", parameters: { type: \"object\", properties: {} } };\n" \
        "export default async function lookup() { return { success: true, message: \"ok\" }; }\n"
      )

      manifest = VatioManifestDirectory.load(dir)

      assert_equal [ "lookup" ], manifest["tools"].map { |tool| tool["key"] }
      refute manifest.key?("workspace"), "workspace.yml is gone; nothing should emit a workspace key"
    end
  end

  def test_manifest_loads_knowledge_sources_yaml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "knowledge"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help visitors.\n")
      File.write(File.join(dir, "knowledge", "sources.yml"), <<~YAML)
        - name: blog
          site_url: https://example.com
          url_pattern: "/blog/**"
      YAML

      manifest = VatioManifestDirectory.load(dir)

      assert_equal [ { "name" => "blog", "site_url" => "https://example.com", "url_pattern" => "/blog/**" } ],
        manifest["knowledge_sources"]
    end
  end

  # Nothing in a workspace is required except agents/main.yml, so an otherwise
  # empty directory still loads.
  def test_manifest_loads_with_no_knowledge_sources_yaml
    Dir.mktmpdir do |dir|
      manifest = VatioManifestDirectory.load(dir)

      assert_equal [], manifest["knowledge_sources"]
      assert_equal({}, manifest["widget"])
      assert_equal({}, manifest["business"])
    end
  end

  # The slug is the directory name, so a manifest never carries it and a
  # leftover workspace.yml is simply ignored rather than being read back in.
  def test_manifest_ignores_a_leftover_workspace_yml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")
      File.write(File.join(dir, "workspace.yml"), "slug: girlslab\nname: Girlslab\n")

      manifest = VatioManifestDirectory.load(dir)

      refute manifest.key?("workspace")
      assert_equal({}, manifest["business"])
      assert_equal({}, manifest["widget"])
    end
  end

  def test_manifest_hoists_the_business_block_out_of_the_entry_agent
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "agents", "main.yml"), <<~YAML)
        key: main
        name: Acme Support
        business:
          name: Acme
          summary: Acme sells warehouse robotics.
        instructions: Help visitors.
      YAML

      manifest = VatioManifestDirectory.load(dir)

      assert_equal({ "name" => "Acme", "summary" => "Acme sells warehouse robotics." },
        manifest["business"])
      refute manifest.dig("agents", "main").key?("business"),
        "business belongs to the workspace, not the agent row"
      assert_equal "Acme Support", manifest.dig("agents", "main", "name")
    end
  end

  def test_manifest_loads_widget_yml_with_its_logo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")
      File.write(File.join(dir, "widget.yml"), <<~YAML)
        accent_color: "#3355FF"
        about: Ask about orders.
        logo: logo.png
        allowed_origins:
          - https://acme.com
      YAML
      File.binwrite(File.join(dir, "logo.png"), ONE_PIXEL_PNG)

      widget = VatioManifestDirectory.load(dir)["widget"]

      assert_equal "#3355FF", widget["accent_color"]
      assert_equal "Ask about orders.", widget["about"]
      assert_equal [ "https://acme.com" ], widget["allowed_origins"]
      assert_equal "logo.png", widget.dig("logo", "filename")
      assert_equal "image/png", widget.dig("logo", "content_type")
      assert_equal ONE_PIXEL_PNG, widget.dig("logo", "content_base64").unpack1("m")
      assert_equal Digest::SHA256.hexdigest(ONE_PIXEL_PNG), widget.dig("logo", "digest")
    end
  end

  def test_manifest_rejects_a_logo_outside_the_workspace_or_of_the_wrong_type
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")

      File.write(File.join(dir, "widget.yml"), "logo: ../escape.png\n")
      escape = assert_raises(ArgumentError) { VatioManifestDirectory.load(dir) }
      assert_match(/inside the workspace/, escape.message)

      File.write(File.join(dir, "widget.yml"), "logo: logo.svg\n")
      File.write(File.join(dir, "logo.svg"), "<svg/>")
      wrong_type = assert_raises(ArgumentError) { VatioManifestDirectory.load(dir) }
      assert_match(/must be one of/, wrong_type.message)

      File.write(File.join(dir, "widget.yml"), "logo: missing.png\n")
      missing = assert_raises(ArgumentError) { VatioManifestDirectory.load(dir) }
      assert_match(/not found/, missing.message)
    end
  end

  # A scheme is its provider file: auth/member.js declares `member`, and the
  # file's own spec carries the options that workspace.yml used to hold.
  def test_manifest_derives_auth_schemes_from_the_provider_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "auth"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")
      File.write(File.join(dir, "auth", "member.js"), <<~JS)
        export const spec = { proactive: true, channels: ["whatsapp"], profile_authoritative: true };
        export async function resolve(ctx) { return { status: "denied" }; }
      JS
      File.write(File.join(dir, "auth", "partner.js"), <<~JS)
        export async function resolve(ctx) { return { status: "denied" }; }
      JS

      manifest = VatioManifestDirectory.load(dir)

      assert_equal(
        {
          "member" => {
            "profile_authoritative" => true, "proactive" => true, "channels" => [ "whatsapp" ]
          },
          "partner" => {
            "profile_authoritative" => false, "proactive" => false, "channels" => []
          }
        },
        manifest.dig("authentication", "schemes")
      )
      # The spec is consumed into the schemes; the wire carries only the source.
      assert_equal [ %w[key source] ], manifest["auth_providers"].map { |row| row.keys.sort }.uniq
      assert_equal 2, manifest["auth_providers"].length
    end
  end

  def test_tools_check_requires_the_main_agent
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "agents", "helper.yml"), "key: helper\ninstructions: Help.\n")

      result = VatioToolsCheck.call(dir)

      refute result.ok?
      assert_includes result.errors.join, "agents must include \"main\""
    end
  end

  def test_tools_check_passes_with_the_main_agent
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")

      assert VatioToolsCheck.call(dir).ok?
    end
  end

  def test_tools_check_points_a_protected_tool_at_its_missing_provider_file
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "tools"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")
      File.write(File.join(dir, "tools", "orders.yml"), <<~YAML)
        description: Orders
        access: member
        request:
          method: GET
          path: /orders
      YAML

      result = VatioToolsCheck.call(dir)

      refute result.ok?
      assert_includes result.errors.join, "create auth/member.js"
    end
  end

  # The filename becomes the scheme name, and a scheme name takes no hyphens —
  # so a dashed provider file could never be referenced by a tool.
  def test_tools_check_rejects_a_dashed_provider_filename
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "auth"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")
      File.write(File.join(dir, "auth", "member-tier.js"), "export async function resolve(c) {}\n")

      result = VatioToolsCheck.call(dir)

      refute result.ok?
      assert_includes result.errors.join, "auth/member-tier.js: the filename is the scheme name"
    end
  end

  def test_tools_check_requires_channels_for_a_proactive_scheme
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "auth"))
      File.write(File.join(dir, "agents", "main.yml"), "key: main\ninstructions: Help.\n")
      File.write(File.join(dir, "auth", "member.js"), <<~JS)
        export const spec = { proactive: true };
        export async function resolve(ctx) { return { status: "denied" }; }
      JS

      result = VatioToolsCheck.call(dir)

      refute result.ok?
      assert_includes result.errors.join, "auth/member.js: proactive requires at least one channel"
    end
  end

  def test_manifest_loads_yaml_declarative_http_tool_alongside_js
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agents"))
      FileUtils.mkdir_p(File.join(dir, "tools"))
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

  def test_manifest_diff_reports_knowledge_source_changes
    local = {
      "knowledge_sources" => [
        { "name" => "blog", "site_url" => "https://example.com", "url_pattern" => "/blog/**" }
      ]
    }
    remote = {
      "knowledge_sources" => [
        { "name" => "blog", "site_url" => "https://example.com", "url_pattern" => "/blog/*" }
      ]
    }

    result = VatioManifestDiff.call(local: local, remote: remote)

    assert_equal [
      { "status" => "modified", "type" => "knowledge_sources", "key" => "blog", "fields" => [ "url_pattern" ] }
    ], result
  end

  def test_sources_reindex_resolves_a_name_to_one_source_id
    reindexed = []
    client = Object.new
    client.define_singleton_method(:reindex_knowledge_source) do |id|
      reindexed << id
      { "id" => id, "name" => "blog", "environment" => "live", "status" => "pending" }
    end
    sources = [ { "id" => 7, "name" => "blog", "environment" => "live" } ]

    cli = VatioCLI.new
    out, = capture_io do
      cli.send(:reindex_source!, client, sources, slug: "acme", name: "blog")
    end

    assert_equal [ 7 ], reindexed
    assert_includes out, "Reindexing blog [live] on workspace acme (status=pending)"
  end

  # A bare name matches once per environment, and reindexing the wrong one is a
  # mistake you only notice later — so it has to stop rather than pick.
  def test_sources_reindex_refuses_an_ambiguous_name
    client = Object.new
    client.define_singleton_method(:reindex_knowledge_source) { |_id| flunk("must not reindex") }
    sources = [
      { "id" => 7, "name" => "blog", "environment" => "live" },
      { "id" => 8, "name" => "blog", "environment" => "preview" }
    ]

    cli = VatioCLI.new
    error = assert_raises(SystemExit) do
      capture_io { cli.send(:reindex_source!, client, sources, slug: "acme", name: "blog") }
    end

    refute_predicate error, :success?
  end

  def test_sources_reindex_requires_a_name
    cli = VatioCLI.new
    client = Object.new
    client.define_singleton_method(:reindex_knowledge_source) { |_id| flunk("must not reindex") }

    assert_raises(SystemExit) do
      capture_io { cli.send(:reindex_source!, client, [], slug: "acme", name: nil) }
    end
  end

  # A workspace root is a directory under a developer root, so pull's tests
  # need both. Yields the workspace path with the cwd inside it.
  def with_workspace(slug: "girlslab")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".vatio"))
      File.write(File.join(dir, ".vatio", "config.json"), JSON.generate(base_url: "https://vatio.ai"))
      workspace = File.join(dir, slug)
      FileUtils.mkdir_p(workspace)

      Dir.chdir(workspace) { yield workspace }
    end
  end

  def test_pull_writes_and_clears_knowledge_sources_yaml
    with_workspace do |workspace|
      cli = VatioCLI.new
      manifest = {
        "knowledge_sources" => [
          { "name" => "blog", "site_url" => "https://example.com", "url_pattern" => "/blog/**" }
        ]
      }

      cli.send(:write_manifest_to_disk!, manifest)
      written = VatioYamlCompat.load_file(File.join(workspace, "knowledge", "sources.yml"))
      assert_equal manifest["knowledge_sources"], written

      cli.send(:write_manifest_to_disk!, manifest.merge("knowledge_sources" => []))
      refute File.exist?(File.join(workspace, "knowledge", "sources.yml"))
    end
  end

  # Pull is the inverse of load: `business` goes back inside agents/main.yml and
  # the widget keys back into widget.yml, so pull → push round-trips.
  def test_pull_restores_business_into_the_entry_agent_and_writes_widget_yml
    with_workspace do |workspace|
      VatioCLI.new.send(:write_manifest_to_disk!, {
        "business" => { "name" => "Acme", "summary" => "Sells robotics." },
        "widget" => {
          "accent_color" => "#3355FF",
          "about" => "Ask about orders.",
          "allowed_origins" => [ "https://acme.com" ]
        },
        "agents" => { "main" => { "key" => "main", "instructions" => "Help." } }
      })

      agent = VatioYamlCompat.load_file(File.join(workspace, "agents", "main.yml"))
      assert_equal({ "name" => "Acme", "summary" => "Sells robotics." }, agent["business"])

      widget = VatioYamlCompat.load_file(File.join(workspace, "widget.yml"))
      assert_equal "#3355FF", widget["accent_color"]
      assert_equal [ "https://acme.com" ], widget["allowed_origins"]

      # Round-trip: loading what pull wrote reproduces the manifest it came from.
      reloaded = VatioManifestDirectory.load(workspace)
      assert_equal({ "name" => "Acme", "summary" => "Sells robotics." }, reloaded["business"])
      assert_equal "#3355FF", reloaded.dig("widget", "accent_color")
    end
  end

  # Revisions keep the logo's name and digest, never its bytes, so pull must not
  # emit a `logo:` line pointing at a file it could not download — that would
  # make the next push fail.
  def test_pull_omits_the_logo_key_and_names_it_in_a_comment
    with_workspace do |workspace|
      VatioCLI.new.send(:write_manifest_to_disk!, {
        "widget" => {
          "accent_color" => "#3355FF",
          "logo" => { "filename" => "logo.png", "content_type" => "image/png", "digest" => "abc123" }
        },
        "agents" => { "main" => { "key" => "main", "instructions" => "Help." } }
      })

      path = File.join(workspace, "widget.yml")
      assert_match(/^# The deployed logo is logo\.png/, File.read(path))
      refute VatioYamlCompat.load_file(path).key?("logo")
      # And what pull wrote still loads, rather than failing on a missing file.
      assert_equal "#3355FF", VatioManifestDirectory.load(workspace).dig("widget", "accent_color")
    end
  end

  def test_pull_removes_widget_yml_when_the_remote_has_no_widget_config
    with_workspace do |workspace|
      path = File.join(workspace, "widget.yml")
      File.write(path, "accent_color: \"#000000\"\n")

      VatioCLI.new.send(:write_manifest_to_disk!, {
        "agents" => { "main" => { "key" => "main", "instructions" => "Help." } }
      })

      refute File.exist?(path)
    end
  end

  # The folder name is the slug: nothing inside the workspace repeats it, and
  # the CLI resolves it from the directory it is standing in.
  def test_workspace_root_and_slug_come_from_the_directory_layout
    with_workspace(slug: "acme") do |workspace|
      config = VatioCliConfig.new(start_dir: workspace)

      assert_equal workspace, config.workspace_root.to_s
      assert_equal "acme", config.resolve_workspace
      assert_equal [ "acme" ], config.local_workspace_slugs

      nested = File.join(workspace, "tools")
      FileUtils.mkdir_p(nested)
      assert_equal workspace, VatioCliConfig.new(start_dir: nested).workspace_root.to_s

      developer_root = File.dirname(workspace)
      assert_nil VatioCliConfig.new(start_dir: developer_root).workspace_root
    end
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

  # The directory name is the slug and agents/main.yml is the only required
  # file, so a new workspace is an empty directory and nothing more.
  def test_workspace_creation_writes_no_files_at_all
    Dir.mktmpdir do |dir|
      workspace = VatioProjectScaffold.new.create_workspace!(dir, slug: "girlslab")
      files = Dir.glob(workspace.join("**", "*"), File::FNM_DOTMATCH).reject { |path| File.directory?(path) }

      assert workspace.directory?
      assert_equal "girlslab", workspace.basename.to_s
      assert_empty files
    end
  end

  def test_version_stays_clean_when_installed_without_a_git_checkout
    Dir.mktmpdir do |dir|
      repo_root = File.expand_path("..", File.dirname(CLI_PATH))
      FileUtils.cp_r(File.join(repo_root, "bin"), dir)
      FileUtils.cp_r(File.join(repo_root, "tools"), dir)

      stdout, stderr, status = Open3.capture3(File.join(dir, "bin", "vatio"), "version", chdir: dir)

      assert status.success?, stderr
      assert_includes stdout, "build unknown"
      assert_empty stderr
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

  def test_update_refuses_to_self_install_over_a_git_checkout
    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(CLI_PATH, "update", chdir: dir)

      refute status.success?
      assert_empty stdout
      assert_match(/git checkout/i, stderr)
      assert_match(/git pull/i, stderr)
    end
  end

  def test_release_check_compares_tags_tolerating_the_v_prefix
    assert VatioReleaseCheck.newer?(current: "0.2.0", latest: "v0.3.0")
    assert VatioReleaseCheck.newer?(current: "0.2.0", latest: "0.2.1")
    refute VatioReleaseCheck.newer?(current: "0.2.0", latest: "v0.2.0")
    refute VatioReleaseCheck.newer?(current: "0.3.0", latest: "v0.2.0")
  end

  def test_release_check_stays_quiet_on_a_missing_or_unparsable_tag
    refute VatioReleaseCheck.newer?(current: "0.2.0", latest: nil)
    refute VatioReleaseCheck.newer?(current: "0.2.0", latest: "")
    refute VatioReleaseCheck.newer?(current: "0.2.0", latest: "nightly")
  end

  def test_release_check_serves_a_fresh_tag_from_cache_without_network
    Dir.mktmpdir do |dir|
      with_env("VATIO_CLI_HOME" => dir) do
        now = Time.now
        VatioReleaseCheck.write_cache(tag: "v9.9.9", now: now)

        assert_equal File.join(dir, "release-check.json"), VatioReleaseCheck.cache_path
        assert_equal "v9.9.9", VatioReleaseCheck.cached_latest_tag(now: now + 60)

        VatioReleaseCheck.clear_cache!

        assert_nil VatioReleaseCheck.read_cache
      end
    end
  end

  def test_release_notice_can_be_switched_off_by_env
    with_env("VATIO_CLI_NO_UPDATE_CHECK" => "1") { assert VatioReleaseCheck.disabled? }
    with_env("VATIO_CLI_NO_UPDATE_CHECK" => nil, "CI" => "true") { assert VatioReleaseCheck.disabled? }
    with_env("VATIO_CLI_NO_UPDATE_CHECK" => nil, "CI" => nil) { refute VatioReleaseCheck.disabled? }
  end

  def test_commands_never_print_the_release_notice_when_output_is_piped
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".vatio"))
      File.write(File.join(dir, ".vatio", "config.json"), JSON.generate(token: "vat_x"))

      stdout, stderr, status = Open3.capture3(CLI_PATH, "version", chdir: dir)

      assert status.success?, stderr
      assert_includes stdout, "Vatio CLI #{VatioCliVersion::VERSION}"
      refute_match(/out of date/i, stderr)
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

  def with_env(vars)
    previous = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def directory_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).to_h do |path|
      [ path.delete_prefix("#{root}/"), File.directory?(path) ? :directory : File.binread(path) ]
    end
  end
end
