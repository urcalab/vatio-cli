# frozen_string_literal: true

require "cgi"
require_relative "http_client"

# HTTP client for the Vatio deploy API (push / publish / rollback).
#
#   client = VatioDeployClient.new(
#     base_url: "http://localhost:3100/api/v1/my-client",
#     token: "vat_…"
#   )
#   client.push_preview(manifest: {...}, git_sha: "abc")
#
class VatioDeployClient < VatioHttpClient
  class UnprocessableError < VatioHttpClient::UnprocessableError
    attr_reader :errors, :warnings

    def initialize(body)
      hash = body.is_a?(Hash) ? body : {}
      @errors = Array(hash["errors"].nil? ? hash["error"] : hash["errors"])
      @warnings = Array(hash["warnings"])
      super(body)
    end
  end

  def status
    get("/deploy/status")
  end

  def manifest(environment: "live")
    get("/deploy/manifest", environment: environment)
  end

  def push_preview(manifest:, git_sha: nil, created_by: nil)
    body = { manifest: manifest }
    body[:git_sha] = git_sha if git_sha
    body[:created_by] = created_by if created_by
    put("/deploy/preview", body)
  end

  def publish(deployment_id: nil, created_by: nil)
    body = {}
    body[:deployment_id] = deployment_id if deployment_id
    body[:created_by] = created_by if created_by
    post("/deploy/publish", body)
  end

  def rollback(created_by: nil)
    body = {}
    body[:created_by] = created_by if created_by
    post("/deploy/rollback", body)
  end

  def revisions
    get("/deploy/revisions")
  end

  def revision(id)
    get("/deploy/revisions/#{id}")
  end

  def destroy_chat(chat_id)
    delete("/chats/#{chat_id}")
  end

  def knowledge_sources(environment: nil)
    params = {}
    params[:environment] = environment if environment
    get("/deploy/knowledge_sources", params)
  end

  # Queues a fresh crawl for one source. Takes an id, not a name — the API
  # addresses sources by id, and a name is only unique within an environment.
  # Returns the source's status object with `status` already "pending".
  def reindex_knowledge_source(id)
    post("/deploy/knowledge_sources/#{CGI.escape(id.to_s)}/reindex", {})
  end

  def list_secrets
    get("/deploy/secrets")
  end

  def upsert_secret(key:, value:)
    put("/deploy/secrets/#{CGI.escape(key.to_s)}", { value: value })
  end

  def delete_secret(key:)
    delete("/deploy/secrets/#{CGI.escape(key.to_s)}")
  end

  private

  def build_unprocessable_error(body)
    UnprocessableError.new(body)
  end
end
