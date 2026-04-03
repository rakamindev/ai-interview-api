# frozen_string_literal: true

class SystemPromptGeneratorWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  def perform(assessment_id)
    assessment = Assessment.find(assessment_id)
    prompt = Assessments::SystemPromptCompiler.new(assessment).call
    assessment.update!(system_prompt: prompt)
    Rails.logger.info("[N2] System prompt generated for assessment #{assessment_id}")
  rescue ActiveRecord::RecordNotFound
    Rails.logger.warn("[N2] Assessment #{assessment_id} not found — skipping")
  end
end
