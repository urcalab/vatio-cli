# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# HTTP client for Vatio CLI device-code auth (/cli/device_authorizations).
class VatioDeviceAuthClient
  class Error < StandardError; end
  class PendingError < Error; end
  class DeniedError < Error; end
  class ExpiredError < Error; end

  def initialize(base_url:)
    @base_url = base_url.to_s.delete_suffix("/")
  end

  def start
    request(:post, "/cli/device_authorizations", {})
  end

  def poll(device_code:)
    request(:post, "/cli/device_authorizations/token", { device_code: device_code })
  end

  private

  def request(method, path, body)
    uri = URI.join("#{@base_url}/", path.sub(%r{\A/}, ""))
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 15
    http.read_timeout = 30

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req.body = JSON.generate(body)

    response = http.request(req)
    parsed = parse_json(response.body)

    case response.code.to_i
    when 200, 201
      if parsed.is_a?(Hash) && parsed["error"] == "authorization_pending"
        raise PendingError, parsed["error_description"] || "authorization_pending"
      end
      parsed
    when 400
      code = parsed.is_a?(Hash) ? parsed["error"] : nil
      raise ExpiredError, parsed["error_description"] || "expired" if code == "expired_token"
      raise DeniedError, parsed["error_description"] || "denied" if code == "access_denied"
      raise Error, (parsed.is_a?(Hash) ? (parsed["error_description"] || parsed["error"]) : response.body)
    when 403, 404
      raise DeniedError, parsed.is_a?(Hash) ? (parsed["error_description"] || parsed["error"]) : response.body
    else
      raise Error, "HTTP #{response.code}: #{parsed.is_a?(Hash) ? parsed : response.body}"
    end
  end

  def parse_json(raw)
    JSON.parse(raw.to_s)
  rescue JSON::ParserError
    {}
  end
end
