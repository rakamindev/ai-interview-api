# frozen_string_literal: true

# Identical to rakamin-api's JsonWebToken.
# Uses the same SECRET_KEY_BASE so tokens issued by rakamin are accepted here.
class JsonWebToken
  HMAC_SECRET = ENV['SECRET_KEY_BASE']
  TOKEN_EXPIRATION_TIME = ENV['TOKEN_EXPIRATION_TIME'].presence

  def self.encode(payload, expire_time = nil)
    if payload[:exp].blank?
      expire_time ||= TOKEN_EXPIRATION_TIME || 3.days
      payload[:exp] = Time.zone.now.to_i + expire_time.to_i
    end

    JWT.encode(payload, HMAC_SECRET)
  end

  def self.decode(token, options = {})
    body = JWT.decode(token, HMAC_SECRET, true, options)[0]
    HashWithIndifferentAccess.new(body)
  rescue JWT::DecodeError => e
    raise ExceptionHandler::InvalidToken, e.message
  end

  def self.decode_without_verification(token)
    body = JWT.decode(token, nil, false)[0]
    HashWithIndifferentAccess.new(body)
  rescue JWT::DecodeError => e
    raise ExceptionHandler::InvalidToken, e.message
  end
end
