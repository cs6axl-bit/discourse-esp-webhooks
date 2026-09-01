# frozen_string_literal: true

module EspWebhooks
  # Audit log of automated actions taken, and the "already acted" guard.
  class Action < ActiveRecord::Base
    self.table_name = "esp_webhook_actions"

    REASONS = %w[complaint unsubscribe hard_bounce].freeze
  end
end
