# frozen_string_literal: true

module Coverage
  # Validates coverage state transitions and enforces hard rules.
  # All transitions are forward-only and probe_count gated.
  class StateEngine
    STATES = %w[not_yet initiated partial covered].freeze

    VALID_TRANSITIONS = {
      'not_yet'   => %w[initiated],
      'initiated' => %w[partial],
      'partial'   => %w[covered],
      'covered'   => []
    }.freeze

    # Returns true if a transition from `from` to `to` is valid given probe_count.
    # min_probes defaults to the runtime-configured minimum (coverage.min_probes_to_advance).
    def self.valid_transition?(from:, to:, probe_count:, min_probes: nil)
      return false unless VALID_TRANSITIONS[from]&.include?(to)

      min_probes ||= AppConfig.get('coverage.min_probes_to_advance')

      # HARD RULE: cannot advance past initiated without the configured minimum probes
      if to == 'partial' || to == 'covered'
        return false if probe_count < min_probes
      end

      true
    end

    # Given a proposed update from N7, returns the safe state to apply.
    # If the proposed state skips steps (e.g. not_yet → partial), we walk
    # forward one step at a time, applying probe_count gates at each step.
    # This prevents the state from getting stuck when Flash proposes a
    # state multiple steps ahead.
    def self.resolve_state(current_state:, proposed_state:, probe_count:, min_probes: nil)
      return current_state if current_state == proposed_state

      min_probes ||= AppConfig.get('coverage.min_probes_to_advance')

      current_idx  = STATES.index(current_state) || 0
      proposed_idx = STATES.index(proposed_state)

      # Unknown proposed state — don't change
      return current_state unless proposed_idx && proposed_idx > current_idx

      # Walk forward one step at a time
      result = current_state
      (current_idx + 1).upto(proposed_idx) do |i|
        candidate = STATES[i]
        break unless valid_transition?(from: result, to: candidate, probe_count: probe_count, min_probes: min_probes)

        result = candidate
      end

      result
    end
  end
end
