# frozen_string_literal: true

module Api
  module V1
    # Runtime configuration for the interview engine.
    # Writes take effect within AppConfig::CACHE_TTL across every Puma and
    # Sidekiq process — no deploy, no restart.
    #
    # Writes are always scoped to the caller's tenant. The global defaults
    # (tenant_id NULL) are ops-only and managed via the app_config rake tasks,
    # so one tenant's admin can never change another tenant's behaviour.
    class SettingsController < ApiController
      authorize_auth_token! :assessor, only: %i[index]
      authorize_auth_token! :admin, only: %i[update bulk_update destroy]

      # GET /api/v1/settings
      def index
        settings = AppConfig.describe(tenant_id: current_tenant_id)
        settings = settings.select { |s| s[:group] == params[:group] } if params[:group].present?

        json_response(
          settings: settings,
          groups:   settings.map { |s| s[:group] }.uniq,
          cache_ttl_seconds: AppConfig::CACHE_TTL.to_i
        )
      end

      # PATCH /api/v1/settings/:key   { "value": 3 }
      def update
        value = AppConfig.set(params[:key], params[:value],
                              tenant_id: current_tenant_id,
                              updated_by: current_user&.id)

        json_response(setting: setting_json(params[:key], value))
      rescue AppConfig::UnknownKey => e
        json_error(e.message, :not_found)
      rescue AppConfig::InvalidValue => e
        json_error(e.message, :unprocessable_entity)
      end

      # PUT /api/v1/settings   { "settings": { "coverage.min_probes_to_advance": 3, ... } }
      # All-or-nothing: one invalid value rejects the whole batch.
      def bulk_update
        updates = params[:settings]
        return json_error("settings must be an object of key => value", :unprocessable_entity) unless updates.respond_to?(:each_pair)

        # Validate everything before writing anything.
        updates.each_pair { |key, value| AppConfig.validate!(AppConfig.definition(key), value) }

        applied = updates.each_pair.map do |key, value|
          AppConfig.set(key, value, tenant_id: current_tenant_id, updated_by: current_user&.id)
          setting_json(key, AppConfig.get(key, tenant_id: current_tenant_id))
        end

        json_response(settings: applied)
      rescue AppConfig::UnknownKey => e
        json_error(e.message, :not_found)
      rescue AppConfig::InvalidValue => e
        json_error(e.message, :unprocessable_entity)
      end

      # DELETE /api/v1/settings/:key — drop this tenant's override.
      def destroy
        value = AppConfig.reset(params[:key], tenant_id: current_tenant_id)
        json_response(setting: setting_json(params[:key], value))
      rescue AppConfig::UnknownKey => e
        json_error(e.message, :not_found)
      end

      private

      def setting_json(key, value)
        definition = AppConfig.definition(key)

        {
          key:         definition.key,
          group:       definition.group,
          type:        definition.type,
          value:       value,
          default:     definition.default,
          description: definition.description
        }
      end
    end
  end
end
