# frozen_string_literal: true

module EspWebhooks
  # Runs the configured automated action for a single parsed webhook event.
  # Called from WebhookController#receive after each esp_webhook_events insert.
  #
  # Current action: disable digest emails for the matching Discourse user
  # (user_options.email_digests = false, digest_after_minutes = 0). For hard
  # bounces, optionally also raise the user's bounce score.
  module Actions
    module_function

    def process(ev, esp_key, event_id)
      return unless SiteSetting.esp_webhooks_actions_enabled

      email = ev[:recipient_email].to_s.strip.downcase
      return if email.blank?

      reason = reason_for(ev)
      return if reason.nil?

      cfg = ::EspWebhooks::ProviderAction.find_by(esp: esp_key.to_s)
      return unless cfg&.enabled_for?(reason)

      user = User.find_by_email(email)
      return if user.nil?

      hard_bounce_count = nil

      if reason == "hard_bounce"
        window = cfg.hard_bounce_window_days.to_i.clamp(1, 365).days.ago
        hard_bounce_count = count_hard_bounces(email, window)
        return if hard_bounce_count < cfg.hard_bounce_threshold.to_i
        return if acted_recently?(user.id, "hard_bounce", window)
      else
        # complaint / unsubscribe: act once, ever
        return if ::EspWebhooks::Action.exists?(user_id: user.id, reason: reason)
      end

      also_bad = (reason == "hard_bounce" && cfg.also_mark_email_bad)
      perform!(user, email, also_bad)

      ::EspWebhooks::Action.create!(
        esp: esp_key.to_s,
        event_id: event_id,
        user_id: user.id,
        recipient_email: email[0, 255],
        reason: reason,
        action: also_bad ? "disable_digests+mark_email_bad" : "disable_digests",
        hard_bounce_count: hard_bounce_count,
        details: { raw_event_type: ev[:raw_event_type].to_s[0, 128] },
      )

      "esp-webhooks action: #{reason} -> user ##{user.id} (#{email}) digests disabled#{also_bad ? " + email marked bad" : ""}"
    rescue => e
      Rails.logger.error("[#{::EspWebhooks::PLUGIN_NAME}] Actions.process failed: #{e.class}: #{e.message}")
      nil
    end

    def reason_for(ev)
      case ev[:event_type].to_s
      when "complaint" then "complaint"
      when "unsubscribe" then "unsubscribe"
      when "bounce" then (::EspWebhooks.hard_bounce?(ev) ? "hard_bounce" : nil)
      end
    end

    def count_hard_bounces(email, since)
      rows = DB.query(<<~SQL, email: email, since: since)
        SELECT event_type, raw_event_type, bounce_class, bounce_reason, severity
        FROM esp_webhook_events
        WHERE lower(recipient_email) = :email
          AND event_type = 'bounce'
          AND received_at >= :since
      SQL

      rows.count do |r|
        ::EspWebhooks.hard_bounce?(
          event_type: "bounce",
          raw_event_type: r.raw_event_type,
          bounce_class: r.bounce_class,
          bounce_reason: r.bounce_reason,
          severity: r.severity,
        )
      end
    end

    def acted_recently?(user_id, reason, since)
      ::EspWebhooks::Action.where(user_id: user_id, reason: reason)
        .where("created_at >= ?", since)
        .exists?
    end

    def perform!(user, email, also_bad)
      opt = user.user_option
      if opt
        begin
          opt.update_columns(
            email_digests: false,
            digest_after_minutes: 0,
            updated_at: Time.now,
          )
        rescue => e
          Rails.logger.error("[#{::EspWebhooks::PLUGIN_NAME}] digest disable failed for ##{user.id}: #{e.class}: #{e.message}")
        end
      end

      return unless also_bad

      stat = user.user_stat
      return unless stat

      begin
        threshold = (SiteSetting.bounce_score_threshold.to_f rescue 4.0)
        threshold = 4.0 if threshold <= 0
        stat.update_columns(
          bounce_score: [stat.bounce_score.to_f, threshold].max,
          reset_bounce_score_after: 90.days.from_now,
        )
      rescue => e
        Rails.logger.error("[#{::EspWebhooks::PLUGIN_NAME}] bounce score bump failed for ##{user.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
