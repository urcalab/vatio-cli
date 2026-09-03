# frozen_string_literal: true

require "fileutils"
require "pathname"
require "yaml"

# Creates only the files explicitly requested by CLI commands (`vatio new workspace`).
class VatioProjectScaffold
  class Error < StandardError; end

  def create_workspace!(parent_dir, slug:, name: nil)
    parent = Pathname(parent_dir).expand_path
    raise Error, "parent directory must exist: #{parent}" unless parent.directory?

    target = parent.join(slug)
    raise Error, "directory already exists: #{target}" if target.exist?

    display_name = name.to_s.strip
    display_name = slug.to_s.tr("-", " ").split.map(&:capitalize).join(" ") if display_name.empty?
    FileUtils.mkdir_p(target)
    target.join("workspace.yml").write(YAML.dump({ "slug" => slug, "name" => display_name }))

    target
  end
end
