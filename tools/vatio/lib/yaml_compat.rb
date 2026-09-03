# frozen_string_literal: true

require "yaml"

# Psych-compatible YAML reader for the standalone CLI.
module VatioYamlCompat
  module_function

  def load_file(path)
    YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false, filename: path.to_s) || {}
  end
end
