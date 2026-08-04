# frozen_string_literal: true

module Api
  module V1
    # Cross-vacancy listing of generated fit/gap reports for the assessor console.
    class FitGapReportsController < ApiController
      authorize_auth_token! :assessor

      # GET /api/v1/fit_gap_reports
      # Optional filters: vacancy_id, assessment_id
      def index
        scope = FitGapReport.includes(:vacancy, portfolio: { session: :assessment })
                            .order(generated_at: :desc)

        # FitGapReport has no tenant_id — scope through the session
        scope = scope.joins(portfolio: :session)
        scope = scope.where(sessions: { tenant_id: Current.tenant_id }) if RequestStore.store.key?(:tenant_id)
        scope = scope.where(vacancy_id: params[:vacancy_id]) if params[:vacancy_id].present?
        scope = scope.where(sessions: { assessment_id: params[:assessment_id] }) if params[:assessment_id].present?
        scope = scope.where('sessions.candidate_name ILIKE ?', "%#{params[:q]}%") if params[:q].present?

        reports = paginate(scope)

        json_response(
          fit_gap_reports: reports.map(&method(:fit_gap_summary_json)),
          meta: {
            current_page: reports.current_page,
            total_pages:  reports.total_pages,
            total_count:  reports.total_count,
            per_page:     reports.limit_value
          }
        )
      end

      private

      def fit_gap_summary_json(report)
        session     = report.portfolio&.session
        comparisons = report.skill_comparisons || []

        {
          id:              report.id,
          portfolio_id:    report.portfolio_id,
          generated_at:    report.generated_at,
          vacancy_id:      report.vacancy_id,
          vacancy_title:   report.vacancy&.role_title,
          session_id:      session&.id,
          candidate_name:  session&.candidate_name,
          assessment_id:   session&.assessment_id,
          assessment_name: session&.assessment&.name,
          match_count:     comparisons.count { |c| c['result'] == 'match' },
          exceed_count:    comparisons.count { |c| c['result'] == 'exceed' },
          gap_count:       comparisons.count { |c| c['result'] == 'gap' },
          not_assessed_count: comparisons.count { |c| c['result'] == 'not_assessed' }
        }
      end
    end
  end
end
