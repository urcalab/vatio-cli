# frozen_string_literal: true

# Plain-Ruby helpers for the Vatio sandbox CLI and HTTP client (no Rails).
module VatioSandboxSupport
  module_function

  def present?(value)
    case value
    when nil, false then false
    when String then !value.empty?
    when Hash, Array then !value.empty?
    else true
    end
  end

  def blank?(value)
    !present?(value)
  end

  def presence(value)
    present?(value) ? value : nil
  end

  def truncate(string, length = 200)
    str = string.to_s
    return str if str.length <= length

    "#{str[0, length - 3]}..."
  end
end
