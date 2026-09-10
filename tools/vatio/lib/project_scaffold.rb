# frozen_string_literal: true

require "fileutils"
require "pathname"

# Creates only what CLI commands explicitly ask for (`vatio new workspace`).
class VatioProjectScaffold
  class Error < StandardError; end

  # The directory name is the workspace slug, and `agents/main.yml` is the only
  # required file — so there is nothing to write here. The workspace starts as
  # an empty directory and the developer adds exactly what they need.
  def create_workspace!(parent_dir, slug:)
    parent = Pathname(parent_dir).expand_path
    raise Error, "parent directory must exist: #{parent}" unless parent.directory?

    target = parent.join(slug)
    raise Error, "directory already exists: #{target}" if target.exist?

    FileUtils.mkdir_p(target)
    target
  end
end
