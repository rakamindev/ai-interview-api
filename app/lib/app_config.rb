# frozen_string_literal: true

# Runtime configuration registry.
#
# Every tunable number in the interview engine is declared here with a code
# default. Operators override values at runtime via the settings API — the
# change is picked up by every Puma and Sidekiq process within CACHE_TTL, with
# no deploy and no restart.
#
# Resolution order for a key:  tenant override → global override → code default.
#
# Usage:
#   AppConfig.get('coverage.min_probes_to_advance', tenant_id: session.tenant_id)
#   AppConfig.all(tenant_id: 12)          # => { "coverage.min_probes_to_advance" => 2, ... }
#   AppConfig.set('coverage.min_probes_to_advance', 3, tenant_id: 12)
module AppConfig
  CACHE_TTL = 30.seconds

  Setting = Struct.new(:key, :type, :default, :min, :max, :group, :description, :public, :env,
                       keyword_init: true) do
    def public? = !!public

    # Legacy ENV fallback, used when no DB override exists.
    def env_value = env && ENV[env].presence
  end

  # rubocop:disable Layout/LineLength
  DEFINITIONS = [
    # ── Coverage / probing ────────────────────────────────────────────────────
    { key: 'coverage.min_probes_to_advance', type: :integer, default: 2, min: 1, max: 10, group: 'coverage',
      description: 'Minimum probes on a skill before it may leave "initiated". Hard-enforced by the state engine.' },
    { key: 'coverage.auto_advance_probe_count', type: :integer, default: 4, min: 1, max: 20, group: 'coverage',
      description: 'Probe count at which a "partial" skill outside the analyzer context window is auto-advanced to "covered".' },
    { key: 'coverage.deep_probe_ceiling', type: :integer, default: 4, min: 1, max: 20, group: 'coverage',
      description: 'Probe count after which the interviewer only keeps digging when pacing=ahead.' },
    { key: 'coverage.max_discovered_skills', type: :integer, default: 10, min: 0, max: 50, group: 'coverage',
      description: 'Maximum off-agenda skills recorded per session.' },
    { key: 'coverage.discovery_max_exchanges', type: :integer, default: 3, min: 1, max: 10, group: 'coverage',
      description: 'Exchanges the interviewer may spend on a discovered skill before returning to the agenda.' },
    { key: 'coverage.analyzer_turns_context', type: :integer, default: 6, min: 2, max: 30, group: 'coverage',
      description: 'Transcript turns sent to the coverage analyzer on each run.' },

    # ── Pacing buckets (minutes left per remaining skill) ─────────────────────
    { key: 'pacing.ahead_min_minutes', type: :float, default: 5.0, min: 0.1, max: 60.0, group: 'pacing',
      description: 'At or above this many minutes per remaining skill, pacing is "ahead".' },
    { key: 'pacing.on_track_min_minutes', type: :float, default: 3.0, min: 0.1, max: 60.0, group: 'pacing',
      description: 'At or above this, pacing is "on_track".' },
    { key: 'pacing.behind_min_minutes', type: :float, default: 1.5, min: 0.1, max: 60.0, group: 'pacing',
      description: 'At or above this, pacing is "behind"; below it, "critical".' },

    # ── Portfolio confidence ──────────────────────────────────────────────────
    { key: 'portfolio.confidence_high_probe_count', type: :integer, default: 3, min: 1, max: 20, group: 'portfolio',
      description: 'Probe count (with state=covered) required for "high" confidence.' },
    { key: 'portfolio.confidence_medium_probe_count', type: :integer, default: 2, min: 1, max: 20, group: 'portfolio',
      description: 'Probe count (or state=partial) that yields "medium" confidence. Below it, "low".' },
    { key: 'portfolio.max_evidence_quotes', type: :integer, default: 3, min: 1, max: 10, group: 'portfolio',
      description: 'Evidence quotes stored per skill.' },

    # ── Session timing ────────────────────────────────────────────────────────
    { key: 'session.time_warning_seconds', type: :integer, default: 120, min: 15, max: 900, group: 'session',
      description: 'Seconds remaining when the interviewer receives the soft time warning.' },
    { key: 'session.wrap_up_warning_seconds', type: :integer, default: 60, min: 10, max: 600, group: 'session',
      description: 'Seconds remaining when the interviewer is told to wrap up.' },
    { key: 'session.time_ceiling_grace_seconds', type: :integer, default: 60, min: 5, max: 600, group: 'session',
      description: 'Grace period after the time limit before the session is force-ended.' },
    { key: 'session.wrap_up_silence_fallback_seconds', type: :integer, default: 20, min: 5, max: 300, group: 'session',
      description: 'How long to wait for a candidate reply before injecting the wrap-up signal anyway.' },
    { key: 'session.closing_phrase_fallback_seconds', type: :integer, default: 15, min: 5, max: 300, group: 'session',
      description: 'Fallback finalizer delay when the AI says a closing phrase but turnComplete never arrives.' },
    { key: 'session.end_poll_max_attempts', type: :integer, default: 30, min: 5, max: 300, group: 'session',
      description: 'One-second polls waiting for the client audio_complete call before ending the session server-side.' },
    { key: 'session.browser_grace_period_seconds', type: :integer, default: 120, min: 10, max: 900, group: 'session',
      description: 'How long the Gemini connection is kept alive after the browser disconnects (page refresh recovery).' },

    # ── Gemini connection ─────────────────────────────────────────────────────
    { key: 'gemini.proactive_reconnect_after_seconds', type: :integer, default: 510, min: 60, max: 3600, group: 'gemini',
      env: 'PROACTIVE_RECONNECT_AFTER',
      description: 'Reconnect proactively this many seconds into a Gemini connection, ahead of its hard limit.' },
    { key: 'gemini.proactive_reconnect_jitter_seconds', type: :integer, default: 30, min: 0, max: 300, group: 'gemini',
      description: 'Random jitter added to the proactive reconnect delay to avoid a thundering herd.' },
    { key: 'gemini.max_reconnect_attempts', type: :integer, default: 3, min: 1, max: 10, group: 'gemini',
      description: 'Reconnect attempts after an unexpected Gemini close before the session is failed.' },
    { key: 'gemini.reconnect_backoff_seconds', type: :integer_array, default: [1, 2, 4], min: 0, max: 120, group: 'gemini',
      description: 'Backoff schedule between reconnect attempts. The last entry repeats if attempts exceed its length.' },
    { key: 'gemini.inactivity_timeout_seconds', type: :integer, default: 30, min: 5, max: 300, group: 'gemini',
      description: 'Silence-pumping idle time after which the Gemini connection is considered dead and recycled.' },
    { key: 'gemini.gate_open_delay_seconds', type: :float, default: 0.8, min: 0.0, max: 10.0, group: 'gemini',
      description: 'Delay before reopening the mic gate after the AI stops speaking (drains the speaker buffer).' },
    { key: 'gemini.silence_pump_delay_seconds', type: :float, default: 1.0, min: 0.1, max: 10.0, group: 'gemini',
      description: 'Silence after the last real mic frame before synthetic silence frames are pumped to trigger Gemini VAD.' },

    # ── Candidate preflight (consumed by the frontend device check) ───────────
    # Live audio is raw PCM, base64-encoded over the WebSocket:
    #   uplink   16kHz x 16-bit mono = 256 kbps, ~341 kbps after base64
    #   downlink 24kHz x 16-bit mono = 384 kbps, ~512 kbps after base64
    # The defaults below are those figures with roughly 2x headroom.
    { key: 'preflight.min_upload_kbps', type: :integer, default: 750, min: 0, max: 100_000, group: 'preflight',
      description: 'Minimum measured upload speed (kbps) for the candidate device check. The live audio uplink needs ~341 kbps.', public: true },
    { key: 'preflight.min_download_kbps', type: :integer, default: 1000, min: 0, max: 100_000, group: 'preflight',
      description: 'Minimum measured download speed (kbps) for the candidate device check. The live audio downlink needs ~512 kbps.', public: true },
    { key: 'preflight.max_ping_ms', type: :integer, default: 300, min: 0, max: 10_000, group: 'preflight',
      description: 'Maximum acceptable round-trip latency to the API for the candidate device check.', public: true },
    { key: 'preflight.speed_test_payload_bytes', type: :integer, default: 262_144, min: 1024, max: 10_485_760, group: 'preflight',
      description: 'Payload size the frontend should upload when measuring speed.', public: true },
    { key: 'preflight.speed_test_timeout_ms', type: :integer, default: 10_000, min: 1000, max: 120_000, group: 'preflight',
      description: 'Timeout for a single speed-test request.', public: true },
    { key: 'preflight.block_below_minimum', type: :boolean, default: true, group: 'preflight',
      description: 'When true the frontend blocks the candidate from starting below the minimum speed; when false it only warns.', public: true }
  ].freeze
  # rubocop:enable Layout/LineLength

  REGISTRY = DEFINITIONS.map { |attrs| [attrs[:key], Setting.new(**attrs)] }.to_h.freeze

  class UnknownKey  < StandardError; end
  class InvalidValue < StandardError; end

  module_function

  def keys = REGISTRY.keys

  def definition(key)
    REGISTRY[key.to_s] or raise UnknownKey, "Unknown setting: #{key}"
  end

  def default(key) = definition(key).default

  # Effective value for a key, honouring tenant → global → env → default.
  def get(key, tenant_id: nil)
    setting = definition(key)
    resolve(setting, overrides(tenant_id), overrides(nil))
  rescue UnknownKey
    raise
  rescue StandardError => e
    # Config must never take the interview down — fall back to the code default.
    Rails.logger.error("[AppConfig] Lookup failed for #{key}: #{e.class} #{e.message}")
    REGISTRY[key.to_s]&.default
  end

  # All effective values, keyed by setting key. Loads each override scope once
  # rather than per key — get/1 would otherwise do 2 lookups per setting.
  def all(tenant_id: nil)
    tenant_over = overrides(tenant_id)
    global_over = overrides(nil)

    REGISTRY.transform_values { |setting| resolve(setting, tenant_over, global_over) }
  end

  # Effective values plus where each one came from — for the settings UI.
  def describe(tenant_id: nil)
    tenant_over = tenant_id ? overrides(tenant_id) : {}
    global_over = overrides(nil)


    REGISTRY.values.map do |setting|
      source = if tenant_over.key?(setting.key)    then 'tenant'
               elsif global_over.key?(setting.key)  then 'global'
               elsif setting.env_value              then 'env'
               else 'default'
               end

      {
        key:         setting.key,
        group:       setting.group,
        type:        setting.type,
        value:       resolve(setting, tenant_over, global_over),
        default:     setting.default,
        min:         setting.min,
        max:         setting.max,
        source:      source,
        description: setting.description
      }
    end
  end

  # Values the candidate-facing frontend is allowed to read without auth.
  def public_values(tenant_id: nil)
    tenant_over = overrides(tenant_id)
    global_over = overrides(nil)

    REGISTRY.values.select(&:public?)
            .to_h { |setting| [setting.key, resolve(setting, tenant_over, global_over)] }
  end

  # Writes an override. tenant_id nil sets the global default for all tenants.
  # Returns the coerced value that was stored.
  def set(key, raw_value, tenant_id: nil, updated_by: nil)
    setting = definition(key)
    value   = validate!(setting, raw_value)

    record = AppSetting.find_or_initialize_by(key: setting.key, tenant_id: tenant_id)
    record.typed_value = value
    record.updated_by  = updated_by
    record.save!

    invalidate(tenant_id)
    value
  end

  # Removes an override so the next level down (global, then code default) applies.
  def reset(key, tenant_id: nil)
    setting = definition(key)
    AppSetting.where(key: setting.key, tenant_id: tenant_id).delete_all
    invalidate(tenant_id)
    get(setting.key, tenant_id: tenant_id)
  end

  def invalidate(tenant_id = nil)
    Rails.cache.delete(cache_key(tenant_id))
    # A global write changes the effective value for every tenant whose cache
    # holds no override of its own — bump the generation so all of them refetch.
    Rails.cache.delete_matched("#{CACHE_NAMESPACE}/*") if tenant_id.nil? && Rails.cache.respond_to?(:delete_matched)
  rescue StandardError => e
    Rails.logger.warn("[AppConfig] Cache invalidation failed: #{e.message}")
  end

  CACHE_NAMESPACE = 'app_config/v1'

  # ── internals ───────────────────────────────────────────────────────────────

  def cache_key(tenant_id) = "#{CACHE_NAMESPACE}/#{tenant_id || 'global'}"

  # Applies the resolution order to already-loaded override scopes.
  def resolve(setting, tenant_over, global_over)
    raw = tenant_over.fetch(setting.key) { global_over.fetch(setting.key, :__missing__) }
    raw = setting.env_value || :__missing__ if raw == :__missing__
    return setting.default if raw == :__missing__

    coerce(setting, raw)
  end

  # Raw (uncoerced) overrides for one scope. Cached so hot paths — coverage
  # injection runs on every turn — don't hit the DB.
  def overrides(tenant_id)
    Rails.cache.fetch(cache_key(tenant_id), expires_in: CACHE_TTL) do
      AppSetting.where(tenant_id: tenant_id).map { |s| [s.key, s.typed_value] }.to_h
    end
  rescue StandardError => e
    Rails.logger.error("[AppConfig] Failed to load overrides (tenant=#{tenant_id.inspect}): #{e.message}")
    {}
  end

  def coerce(setting, raw)
    case setting.type
    when :integer       then raw.to_i
    when :float         then raw.to_f
    when :boolean       then ActiveModel::Type::Boolean.new.cast(raw) || false
    when :integer_array then Array(raw).map(&:to_i)
    else raw
    end
  end

  def validate!(setting, raw)
    value = coerce(setting, raw)

    case setting.type
    when :integer
      raise InvalidValue, "#{setting.key} must be a whole number" unless raw.to_s.match?(/\A-?\d+\z/)

      check_range!(setting, value)
    when :float
      raise InvalidValue, "#{setting.key} must be a number" unless raw.to_s.match?(/\A-?\d+(\.\d+)?\z/)

      check_range!(setting, value)
    when :integer_array
      raise InvalidValue, "#{setting.key} must be a non-empty list of numbers" if value.empty?

      value.each { |v| check_range!(setting, v) }
    when :boolean
      raise InvalidValue, "#{setting.key} must be true or false" if ActiveModel::Type::Boolean.new.cast(raw).nil?
    end

    value
  end

  def check_range!(setting, value)
    if setting.min && value < setting.min
      raise InvalidValue, "#{setting.key} must be >= #{setting.min}"
    end
    if setting.max && value > setting.max
      raise InvalidValue, "#{setting.key} must be <= #{setting.max}"
    end
  end
end
