# frozen_string_literal: true

module Api
  module V1
    class UsersController < ApiController
      skip_before_action :require_tenant!

      # POST /api/v1/signup
      def create
        user = User.new(
          email:    params[:email],
          password: params[:password],
          role:     params[:role].presence || 'user'
        )

        if user.save
          scheme = resolve_scheme
          token  = JsonWebToken.encode({ user_id: user.id, role: user.role, scheme: })

          json_response({ token:, user: { id: user.id, email: user.email, role: user.role } }, :created)
        else
          json_error(user.errors.full_messages.first, :unprocessable_entity)
        end
      end

      private

      def resolve_scheme
        request.headers['X-Tenant-Scheme'].presence ||
          ActiveRecord::Base.connection.select_value(
            "SELECT scheme FROM public.organizations LIMIT 1"
          ) || 'test-corp'
      end
    end
  end
end
