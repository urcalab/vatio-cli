# frozen_string_literal: true

require_relative "http_client"

# HTTP client for Vatio CLI workspace API (/cli/workspaces).
class VatioWorkspacesClient < VatioHttpClient
  def list
    get("/cli/workspaces")
  end

  def create(slug:, name: nil)
    body = { slug: slug }
    body[:name] = name if name.to_s.strip != ""
    post("/cli/workspaces", body)
  end

  def exists?(slug)
    Array(list["workspaces"]).any? { |workspace| workspace["slug"].to_s == slug.to_s }
  end
end
