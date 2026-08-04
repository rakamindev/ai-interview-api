# frozen_string_literal: true

# Runtime-tunable configuration. Rows override the code defaults declared in
# AppConfig::REGISTRY, so operators can change thresholds without a deploy.
# tenant_id NULL = global default for every tenant.
class CreateAppSettings < ActiveRecord::Migration[7.0]
  def up
    execute "SET search_path TO ai_interview, public"

    create_table :app_settings do |t|
      t.bigint   :tenant_id
      t.string   :key,        null: false, limit: 100
      t.jsonb    :value,      null: false
      t.bigint   :updated_by
      t.timestamps
    end

    # Postgres treats NULLs as distinct in unique indexes, so the global rows
    # (tenant_id IS NULL) need their own partial unique index.
    add_index :app_settings, %i[tenant_id key], unique: true,
                                                where: 'tenant_id IS NOT NULL',
                                                name: 'idx_app_settings_tenant_key'
    add_index :app_settings, :key, unique: true,
                                   where: 'tenant_id IS NULL',
                                   name: 'idx_app_settings_global_key'
  end

  def down
    drop_table :app_settings
  end
end
