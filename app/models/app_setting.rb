# frozen_string_literal: true

# A single runtime configuration override. Deliberately NOT TenantScoped:
# a NULL tenant_id row is the global default and must stay readable from every
# tenant context (and from Sidekiq, where Current.tenant_id is not set).
#
# Reads go through AppConfig — do not query this model directly from app code.
class AppSetting < ApplicationRecord
  validates :key, presence: true,
                  inclusion: { in: -> (_) { AppConfig.keys }, message: 'is not a known setting' },
                  uniqueness: { scope: :tenant_id }

  scope :global, -> { where(tenant_id: nil) }
  scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }

  # `value` is jsonb wrapping the scalar/array as { "v" => ... } so booleans,
  # floats and arrays all round-trip without type guessing.
  def typed_value
    value.is_a?(Hash) ? value['v'] : value
  end

  def typed_value=(raw)
    self.value = { 'v' => raw }
  end
end
