# frozen_string_literal: true

require "json"

# Produces a bounded, source-free summary of manifest changes.
class VatioManifestDiff
  COLLECTIONS = {
    "agents" => :hash,
    "knowledge" => :source,
    "knowledge_sources" => :name,
    "tools" => :key,
    "libs" => :key,
    "auth_providers" => :key
  }.freeze
  SINGLETONS = %w[workspace authentication].freeze

  def self.call(local:, remote:)
    new(local: local, remote: remote).changes
  end

  def initialize(local:, remote:)
    @local = local || {}
    @remote = remote || {}
  end

  def changes
    singleton_changes + collection_changes
  end

  private

  def singleton_changes
    SINGLETONS.each_with_object([]) do |type, result|
      change = change_for(type, type, @local[type], @remote[type])
      result << change if change
    end
  end

  def collection_changes
    COLLECTIONS.flat_map do |type, identity|
      local_entries = index(@local[type], identity)
      remote_entries = index(@remote[type], identity)
      (local_entries.keys | remote_entries.keys).sort.each_with_object([]) do |key, result|
        change = change_for(type, key, local_entries[key], remote_entries[key])
        result << change if change
      end
    end
  end

  def index(value, identity)
    return stringify_hash(value) if identity == :hash

    Array(value).each_with_index.to_h do |entry, index|
      row = entry.is_a?(Hash) ? entry : {}
      key = row[identity.to_s].to_s
      key = row["title"].to_s if key.empty? && identity == :source
      key = (index + 1).to_s if key.empty?
      [ key, row ]
    end
  end

  def stringify_hash(value)
    return {} unless value.is_a?(Hash)

    value.to_h { |key, entry| [ key.to_s, entry ] }
  end

  def change_for(type, key, local, remote)
    return if local == remote

    status = if remote.nil?
      "added"
    elsif local.nil?
      "removed"
    else
      "modified"
    end
    {
      "status" => status,
      "type" => type,
      "key" => key,
      "fields" => changed_fields(local, remote)
    }
  end

  def changed_fields(local, remote)
    return [] unless local.is_a?(Hash) && remote.is_a?(Hash)

    (local.keys.map(&:to_s) | remote.keys.map(&:to_s)).select do |key|
      fetch(local, key) != fetch(remote, key)
    end.sort
  end

  def fetch(hash, key)
    return hash[key] if hash.key?(key)

    hash[key.to_sym]
  end
end
