# frozen_string_literal: true

require 'digest'

module Coverage
  # Builds the coverage map JSON payload for injection into Gemini Live context.
  # Called synchronously before each AI response — must be < 50ms.
  class MapInjector
    def initialize(session)
      @session = session
    end

    # Returns a fingerprint of coverage state only (excludes time_remaining so
    # a pure clock tick doesn't trigger a redundant re-injection).
    def coverage_fingerprint
      maps = @session.coverage_maps.order(:id)
      Digest::MD5.hexdigest(maps.map { |m| "#{m.id}:#{m.state}:#{m.probe_count}" }.join(','))
    end

    # Returns the formatted injection string to send via realtimeInput.text.
    def injection_text
      maps = @session.coverage_maps.includes(:session)
      configured = maps.configured.order(:id)
      discovered = maps.discovered.order(:id)

      payload = {
        skills:                 configured.map { |m| skill_json(m) },
        discovered:             discovered.map { |m| skill_json(m) },
        time_remaining_minutes: time_remaining_minutes,
        priority_next:          priority_next(configured)
      }

      "[COVERAGE_MAP]\n#{payload.to_json}\n[/COVERAGE_MAP]"
    end

    private

    def skill_json(map)
      {
        id:          map.skill_id || map.skill_label.downcase.gsub(/\s+/, '-'),
        label:       map.skill_label,
        state:       map.state,
        probe_count: map.probe_count
      }
    end

    def time_remaining_minutes
      return nil unless @session.started_at && @session.assessment.time_limit_min

      elapsed_seconds = (Time.current - @session.started_at).to_i
      limit_seconds   = @session.assessment.time_limit_min * 60
      remaining       = limit_seconds - elapsed_seconds

      [(remaining / 60.0).ceil, 0].max
    end

    # Returns the skill_id/label of the highest-priority uncovered skill.
    # Priority: not_yet > initiated > partial > discovered > covered
    def priority_next(configured_maps)
      priority_order = %w[not_yet initiated partial covered]

      best = configured_maps
               .reject { |m| m.state == 'covered' }
               .min_by { |m| priority_order.index(m.state) || 999 }

      return nil unless best

      best.skill_id || best.skill_label.downcase.gsub(/\s+/, '-')
    end
  end
end
