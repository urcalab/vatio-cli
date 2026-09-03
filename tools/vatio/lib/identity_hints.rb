# frozen_string_literal: true

# Shared email/phone/channel normalization for Vatio sandbox CLI and backend.
# Keep in sync with backend/lib/vatio/identity_hints.rb.
module VatioIdentityHints
  SIMULATED_CHANNELS = %w[cli web whatsapp email instagram].freeze
  EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  module_function

  def normalize_email(email)
    value = email.to_s.strip.downcase
    value.empty? ? nil : value
  end

  def normalize_phone(phone)
    value = phone.to_s.strip.gsub(/\s+/, "")
    value.empty? ? nil : value
  end

  def normalize_channel(channel)
    value = channel.to_s.strip.downcase
    return "cli" if value.empty? || value == "sandbox"

    value
  end

  # Resolve simulated ingress for CLI/API. Never establishes AuthenticationSession.
  #
  # Returns a hash with:
  #   channel, from_label, external_ref, email, phone_number
  # or { error: :…, message: "…" }
  def resolve_simulation(channel:, from: nil, token_prefix: nil, session_id: nil)
    ch = normalize_channel(channel)
    unless SIMULATED_CHANNELS.include?(ch)
      return {
        error: :invalid_channel,
        message: "invalid channel #{channel.inspect} (allowed: #{SIMULATED_CHANNELS.join(", ")})"
      }
    end

    from_value = from.to_s.strip
    from_value = nil if from_value.empty?
    prefix = token_prefix.to_s.strip
    sid = session_id.to_s.strip
    sid = "default" if sid.empty?

    case ch
    when "whatsapp"
      return missing_from!("whatsapp", "phone number") if from_value.nil?

      phone = normalize_phone(from_value)
      return invalid_from!("whatsapp", "phone number") if phone.nil? || !phone.match?(/\A\+?\d{8,15}\z/)

      {
        channel: ch,
        from_label: phone,
        external_ref: phone,
        email: nil,
        phone_number: phone
      }
    when "email"
      return missing_from!("email", "email address") if from_value.nil?

      email = normalize_email(from_value)
      return invalid_from!("email", "email address") if email.nil? || !email.match?(EMAIL_FORMAT)

      {
        channel: ch,
        from_label: email,
        external_ref: email,
        email: email,
        phone_number: nil
      }
    when "instagram"
      return missing_from!("instagram", "external ref") if from_value.nil?

      {
        channel: ch,
        from_label: from_value,
        external_ref: from_value,
        email: nil,
        phone_number: nil
      }
    when "web"
      email = nil
      phone = nil
      if from_value
        if from_value.include?("@")
          email = normalize_email(from_value)
          return invalid_from!("web", "email address") if email.nil? || !email.match?(EMAIL_FORMAT)
        else
          phone = normalize_phone(from_value)
          return invalid_from!("web", "phone or email") if phone.nil?
        end
      end

          external_ref =
            if email
              "web:email:#{email}"
            elsif phone
              "web:phone:#{phone}"
            else
              stable_session_ref(prefix, sid)
            end

      {
        channel: ch,
        from_label: from_value,
        external_ref: external_ref,
        email: email,
        phone_number: phone
      }
    else # cli
      email = nil
      phone = nil
      if from_value
        if from_value.include?("@")
          email = normalize_email(from_value)
          return invalid_from!("cli", "email address") if email.nil? || !email.match?(EMAIL_FORMAT)
        else
          phone = normalize_phone(from_value)
          return invalid_from!("cli", "phone or email") if phone.nil?
        end
      end

      {
        channel: ch,
        from_label: from_value,
        external_ref: stable_session_ref(prefix, sid),
        email: email,
        phone_number: phone
      }
    end
  end

  def stable_session_ref(prefix, session_id)
    raise ArgumentError, "token_prefix required for anonymous cli/web simulation" if prefix.to_s.strip.empty?

    "#{prefix}:#{session_id}"
  end

  def missing_from!(channel, kind)
    { error: :missing_from, message: "#{channel} requires --from with a #{kind}" }
  end

  def invalid_from!(channel, kind)
    { error: :invalid_from, message: "#{channel} requires a valid #{kind}" }
  end

  # Parse API request identity fields. Returns :error => :both_set when invalid.
  def from_params(email: nil, phone_number: nil)
    normalized_email = normalize_email(email)
    normalized_phone = normalize_phone(phone_number)

    if normalized_email && normalized_phone
      return { error: :both_set }
    end

    { email: normalized_email, phone_number: normalized_phone }
  end
end
