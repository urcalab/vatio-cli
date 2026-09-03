# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Shared Net::HTTP + Bearer JSON client for Vatio deploy/sandbox CLIs.
class VatioHttpClient
  class Error < StandardError
    attr_reader :status, :request_id, :body

    def initialize(message = nil, status: nil, request_id: nil, body: nil)
      @status = status
      @request_id = request_id
      @body = body.is_a?(Hash) ? body : {}
      super(message)
    end
  end
  class UnauthorizedError < Error; end
  class ForbiddenError < Error; end
  class NotFoundError < Error; end

  class UnprocessableError < Error
    attr_reader :body

    def initialize(body)
      @body = body.is_a?(Hash) ? body : {}
      super(
        unprocessable_message(@body),
        status: 422,
        request_id: @body["request_id"],
        body: @body
      )
    end

    private

    def unprocessable_message(body)
      errors = Array(body["errors"]).compact
      return errors.join("; ") unless errors.empty?

      msg = body["error_message"] || body["error"]
      return Array(msg).join("; ") if msg

      "Unprocessable"
    end
  end

  def initialize(base_url:, token:)
    @base_url = base_url.to_s.delete_suffix("/")
    @token = token.to_s
    raise ArgumentError, "base_url is required" if @base_url.empty?
    raise ArgumentError, "token is required" if @token.empty?
  end

  private

  attr_reader :base_url, :token

  def get(path, params = {})
    uri = URI.parse("#{base_url}#{path}")
    uri.query = URI.encode_www_form(params) if params.respond_to?(:any?) && params.any?
    request = Net::HTTP::Get.new(uri)
    perform(uri, request)
  end

  def post(path, body = {})
    uri = URI.parse("#{base_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    perform(uri, request)
  end

  def put(path, body = {})
    uri = URI.parse("#{base_url}#{path}")
    request = Net::HTTP::Put.new(uri)
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    perform(uri, request)
  end

  def delete(path)
    uri = URI.parse("#{base_url}#{path}")
    request = Net::HTTP::Delete.new(uri)
    perform(uri, request)
  end

  def perform(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 120

    request["Authorization"] = "Bearer #{token}"
    request["Accept"] = "application/json"

    parse_response(http.request(request))
  rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
    raise Error, e.message
  end

  def parse_response(response)
    status = response.code.to_i
    body = parse_json(response.body)
    request_id = body&.[]("request_id") || response["X-Request-Id"]
    message = response_message(body, response)

    case status
    when 200..299
      return {} if response.body.to_s.strip.empty?

      raise Error.new("HTTP #{status}: invalid JSON", status: status, request_id: request_id) unless body

      body
    when 401
      raise UnauthorizedError.new(message, status: status, request_id: request_id, body: body)
    when 403
      raise ForbiddenError.new(message, status: status, request_id: request_id, body: body)
    when 404
      raise NotFoundError.new(message, status: status, request_id: request_id, body: body)
    when 422
      raise build_unprocessable_error(body)
    else
      raise Error.new("HTTP #{status}: #{message}", status: status, request_id: request_id, body: body)
    end
  end

  def parse_json(raw)
    return {} if raw.to_s.strip.empty?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : { "data" => parsed }
  rescue JSON::ParserError
    nil
  end

  def response_message(body, response)
    if body
      value = body["error_description"] || body["error_message"] || body["error"]
      value = value["message"] if value.is_a?(Hash)
      return Array(value).join("; ") unless value.nil?
    end

    text = response.body.to_s.strip
    return response.message if text.empty? || text.start_with?("<")

    text[0, 200]
  end

  def build_unprocessable_error(body)
    UnprocessableError.new(body)
  end
end
