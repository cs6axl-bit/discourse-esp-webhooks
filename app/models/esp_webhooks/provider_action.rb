# frozen_string_literal: true

module EspWebhooks
  # Per-provider automated-action config (one row per recognized ESP).
  class ProviderAction < ActiveRecord::Base
    self.table_name = "esp_webhook_provider_actions"

    validates :esp, presence: true, uniqueness: true
    validates :hard_bounce_threshold, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 50 }
    validates :hard_bounce_window_days, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 365 }

    def enabled_for?(reason)
      case reason.to_s
      when "complaint" then on_complaint
      when "unsubscribe" then on_unsubscribe
      when "hard_bounce" then on_hard_bounce
      else false
      end
    end

    def self.seed!
      return unless table_exists?

      ::EspWebhooks::RECOGNIZED_ESPS.each do |esp|
        create!(esp: esp) unless exists?(esp: esp)
      end
    rescue => e
      Rails.logger.warn("[discourse-esp-webhooks] ProviderAction.seed! failed: #{e.class}: #{e.message}")
    end
  end
end
