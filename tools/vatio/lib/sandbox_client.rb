# frozen_string_literal: true

require_relative "http_client"
require_relative "sandbox_support"

# HTTP client for programmatic Vatio preview chats (`/api/v1/:ws/chats`).
# `environment` is only sent on the two actions with no existing chat to read
# it from (create/reset) — this client always sends "preview", since CLI
# chats never talk to live.
#
#   client = VatioSandboxClient.new(
#     sandbox_url: "http://localhost:3100/api/v1/my-client",
#     token: "vat_…"
#   )
#
class VatioSandboxClient < VatioHttpClient
  include VatioSandboxSupport

  class UnprocessableError < VatioHttpClient::UnprocessableError
    attr_reader :error_key, :error_message

    def initialize(body)
      hash = body.is_a?(Hash) ? body : {}
      @error_key = hash["error_key"]
      @error_message = hash["error_message"]
      super(body)
    end
  end

  def initialize(sandbox_url:, token:, track: :preview)
    # track is accepted for backward compatibility; CLI always uses preview sandbox API.
    raise ArgumentError, "CLI chats only support preview (got #{track.inspect})" if track.to_sym != :preview

    super(base_url: sandbox_url, token: token)
  end

  def create_chat(session_id: nil, channel: "cli", from: nil)
    body = { "environment" => "preview", "channel" => channel }
    body["session_id"] = session_id if present?(session_id)
    body["from"] = from if present?(from)
    post("/chats", body)
  end

  def reset_chat_for(chat_id:, session_id: nil, channel: "cli", from: nil)
    body = { "environment" => "preview", "channel" => channel }
    body["session_id"] = session_id if present?(session_id)
    body["from"] = from if present?(from)
    post("/chats/#{chat_id}/reset", body)
  end

  def show_chat(chat_id, view: "visitor")
    get("/chats/#{chat_id}", view: view)
  end

  def messages(chat_id, view: "visitor", after: nil, limit: nil)
    params = { view: view }
    params[:after] = after if present?(after)
    params[:limit] = limit if present?(limit)
    get("/chats/#{chat_id}/messages", params)
  end

  def send_message(chat_id:, content:)
    post("/chats/#{chat_id}/messages", { content: content })
  end

  def wait_for_assistant(chat_id:, after_message_id:, timeout: 120, interval: 2, view: "visitor")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f

    loop do
      payload = messages(chat_id, view: view, after: after_message_id)
      assistant = payload.fetch("data", []).reverse.find do |message|
        message["role"] == "assistant" && present?(message["content"].to_s.strip)
      end
      return assistant if assistant

      raise Error, "Timed out waiting for assistant reply after #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep interval
    end
  end

  private

  def build_unprocessable_error(body)
    UnprocessableError.new(body)
  end
end
