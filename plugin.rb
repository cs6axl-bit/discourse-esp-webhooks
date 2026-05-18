# frozen_string_literal: true

# name: discourse-esp-webhooks
# about: Receives and logs ESP webhook/postback events (bounces, unsubs, spam complaints) from SparkPost, Elastic Email, ReachMail, InboxRoad, Mailgun
# version: 1.0.0
# authors: you

enabled_site_setting :esp_webhooks_enabled

after_initialize do
  require "json"

  # ---------------------------------------------------------------------------
  # Module
  # ---------------------------------------------------------------------------

  module ::EspWebhooks
    PLUGIN_NAME = "discourse-esp-webhooks"
    RECOGNIZED_ESPS = %w[sparkpost elasticemail reachmail inboxroad mailgun].freeze
    MAX_BODY_SIZE = 1_048_576 # 1 MB safety cap

    def self.normalize_esp(val)
      return nil if val.blank?
      val.to_s.strip.downcase.gsub(/[^a-z0-9]/, "")
    end
  end

  # ---------------------------------------------------------------------------
  # Engine
  # ---------------------------------------------------------------------------

  class ::EspWebhooks::Engine < ::Rails::Engine
    engine_name "esp_webhooks"
    isolate_namespace EspWebhooks
  end

  # ---------------------------------------------------------------------------
  # Parsers — one sub-module per ESP
  # Returns nil when payload cannot be parsed, or an Array of event hashes.
  # Every hash has these keys:
  #   event_type, raw_event_type, recipient_email, sender_email,
  #   message_id, subject, bounce_class, bounce_reason, severity, raw_event_json
  # ---------------------------------------------------------------------------

  module ::EspWebhooks::Parsers
    def self.parse(esp_key, body_str, content_type)
      case esp_key
      when "sparkpost"    then SparkPost.parse(body_str)
      when "elasticemail" then ElasticEmail.parse(body_str, content_type)
      when "inboxroad"    then InboxRoad.parse(body_str)
      when "mailgun"      then Mailgun.parse(body_str)
      when "reachmail"    then ReachMail.parse(body_str, content_type)
      end
    rescue => e
      Rails.logger.warn("[#{::EspWebhooks::PLUGIN_NAME}] parser error (#{esp_key}): #{e.class}: #{e.message}")
      nil
    end

    # -------------------------------------------------------------------------
    # SparkPost
    # Sends a JSON array of wrapper objects: [{"msys":{"message_event":{...}}}]
    # Relevant types: bounce, out_of_band, spam_complaint, list_unsubscribe,
    #                 link_unsubscribe
    # -------------------------------------------------------------------------
    module SparkPost
      TYPE_MAP = {
        "bounce"           => "bounce",
        "out_of_band"      => "bounce",
        "spam_complaint"   => "complaint",
        "list_unsubscribe" => "unsubscribe",
        "link_unsubscribe" => "unsubscribe",
      }.freeze

      def self.parse(body_str)
        data = JSON.parse(body_str)
        data = [data] unless data.is_a?(Array)

        events = []
        data.each do |wrapper|
          msys = wrapper["msys"] || {}
          # SparkPost uses different sub-keys depending on event category
          ev = msys["message_event"] ||
               msys["unsubscribe_event"] ||
               msys["track_event"] ||
               msys["gen_event"] ||
               {}
          next if ev.empty?

          raw_type  = ev["type"].to_s
          norm_type = TYPE_MAP[raw_type] || raw_type

          events << {
            event_type:      norm_type,
            raw_event_type:  raw_type,
            recipient_email: ev["rcpt_to"],
            sender_email:    ev["msg_from"],
            message_id:      ev["message_id"],
            subject:         ev["subject"],
            bounce_class:    ev["bounce_class"],
            bounce_reason:   ev["raw_reason"] || ev["reason"],
            severity:        nil,
            raw_event_json:  JSON.generate(ev),
          }
        end
        events.empty? ? nil : events
      end
    end

    # -------------------------------------------------------------------------
    # Elastic Email
    # Sends form-encoded POST (or JSON).
    # Fields: from, to, date, subject, status, channel, account, messageid,
    #         transaction, category
    # status values: "*Error" / "Bounced" => bounce
    #                "Unsubscribed"        => unsubscribe
    #                "AbuseReport"         => complaint
    # -------------------------------------------------------------------------
    module ElasticEmail
      def self.parse(body_str, content_type)
        params = if content_type.to_s.include?("application/json")
          JSON.parse(body_str)
        else
          Rack::Utils.parse_nested_query(body_str)
        end

        status    = params["status"].to_s
        norm_type = normalize_status(status)

        [{
          event_type:      norm_type || "unknown",
          raw_event_type:  status,
          recipient_email: params["to"],
          sender_email:    params["from"],
          message_id:      params["messageid"],
          subject:         params["subject"],
          bounce_class:    params["category"],
          bounce_reason:   nil,
          severity:        nil,
          raw_event_json:  JSON.generate(params),
        }]
      end

      def self.normalize_status(s)
        return "bounce"      if s.end_with?("Error") || s == "Bounced"
        return "unsubscribe" if s == "Unsubscribed"
        return "complaint"   if s == "AbuseReport"
        nil
      end
    end

    # -------------------------------------------------------------------------
    # InboxRoad (PowerMTA-based)
    # Sends JSON array or single JSON object.
    # Fields: type, timeLogged, orig, rcpt, dsnAction, dsnStatus, dsnDiag,
    #         bounceCat, rcvSmtpUser, header_Message-Id, vmta
    # type: "b"/"rb" => bounce, "f" => complaint, "d" => delivered (skipped)
    # -------------------------------------------------------------------------
    module InboxRoad
      TYPE_MAP = {
        "b"  => "bounce",
        "rb" => "bounce",
        "f"  => "complaint",
      }.freeze

      def self.parse(body_str)
        data = JSON.parse(body_str)
        data = [data] unless data.is_a?(Array)

        events = []
        data.each do |ev|
          raw_type  = ev["type"].to_s
          norm_type = TYPE_MAP[raw_type]
          next unless norm_type # skip delivered ("d") and unknown

          events << {
            event_type:      norm_type,
            raw_event_type:  raw_type,
            recipient_email: ev["rcpt"],
            sender_email:    ev["orig"],
            message_id:      ev["header_Message-Id"],
            subject:         nil,
            bounce_class:    ev["bounceCat"],
            bounce_reason:   ev["dsnDiag"],
            severity:        ev["dsnStatus"],
            raw_event_json:  JSON.generate(ev),
          }
        end
        events.empty? ? nil : events
      end
    end

    # -------------------------------------------------------------------------
    # Mailgun
    # Sends JSON: {"event-data": {...}} (v3 API)
    # event values: "failed" => bounce, "unsubscribed" => unsubscribe,
    #               "complained" => complaint
    # -------------------------------------------------------------------------
    module Mailgun
      EVENT_MAP = {
        "failed"       => "bounce",
        "unsubscribed" => "unsubscribe",
        "complained"   => "complaint",
      }.freeze

      def self.parse(body_str)
        data     = JSON.parse(body_str)
        ev       = data["event-data"] || data
        raw_type = ev["event"].to_s
        norm     = EVENT_MAP[raw_type]
        return nil unless norm

        delivery = ev["delivery-status"] || {}

        [{
          event_type:      norm,
          raw_event_type:  raw_type,
          recipient_email: ev["recipient"],
          sender_email:    ev.dig("envelope", "sender") ||
                           ev.dig("message", "headers", "from"),
          message_id:      ev.dig("message", "headers", "message-id"),
          subject:         ev.dig("message", "headers", "subject"),
          bounce_class:    delivery["bounce-type"],
          bounce_reason:   delivery["message"] || delivery["description"],
          severity:        ev["severity"],
          raw_event_json:  JSON.generate(ev),
        }]
      end
    end

    # -------------------------------------------------------------------------
    # ReachMail / EasySMTP
    # ReachMail does not publish a public webhook spec; this parser handles
    # both form-encoded and JSON POST bodies and tries common field names.
    # Update field mappings here once you confirm the exact payload your
    # ReachMail account sends (check raw_body in esp_webhook_raw_logs).
    # -------------------------------------------------------------------------
    module ReachMail
      def self.parse(body_str, content_type)
        params = if content_type.to_s.include?("application/json")
          JSON.parse(body_str)
        else
          Rack::Utils.parse_nested_query(body_str)
        end

        raw_type  = (params["EventType"] || params["event_type"] ||
                     params["Status"]    || params["status"] || params["type"]).to_s
        norm_type = normalize_event(raw_type)

        [{
          event_type:      norm_type || "unknown",
          raw_event_type:  raw_type,
          recipient_email: params["Recipient"] || params["recipient"] ||
                           params["Email"]     || params["email"],
          sender_email:    params["From"]   || params["from"]   || params["Sender"],
          message_id:      params["MessageID"] || params["message_id"] || params["MessageId"],
          subject:         params["Subject"] || params["subject"],
          bounce_class:    params["BounceType"] || params["bounce_type"] || params["Category"],
          bounce_reason:   params["Description"] || params["Reason"]  || params["reason"],
          severity:        nil,
          raw_event_json:  JSON.generate(params),
        }]
      end

      def self.normalize_event(e)
        e = e.to_s.downcase
        return "bounce"      if e.include?("bounce") || e.include?("hard") || e.include?("soft")
        return "unsubscribe" if e.include?("unsub")
        return "complaint"   if e.include?("spam") || e.include?("complaint") || e.include?("abuse")
        nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Controller
  # Inherits ActionController::Base (NOT ApplicationController) so Discourse
  # auth middleware is bypassed — same pattern as discourse-content-redirector.
  # ---------------------------------------------------------------------------

  class ::EspWebhooks::WebhookController < ::ActionController::Base
    protect_from_forgery with: :null_session

    def receive
      return render(plain: "disabled", status: 404) unless SiteSetting.esp_webhooks_enabled

      esp_param   = params[:esp].to_s.presence
      event_param = params[:event].to_s.presence

      raw_body = request.body.read.to_s
      raw_body = raw_body[0, ::EspWebhooks::MAX_BODY_SIZE] if raw_body.length > ::EspWebhooks::MAX_BODY_SIZE

      raw_headers = request
        .headers
        .env
        .select { |k, _| k.start_with?("HTTP_") || %w[CONTENT_TYPE CONTENT_LENGTH].include?(k) }
        .map { |k, v| "#{k}: #{v}" }
        .join("\n")

      # --- Insert raw log and capture its ID --------------------------------
      raw_log_id = nil
      begin
        ids = DB.query_single(<<~SQL,
          INSERT INTO esp_webhook_raw_logs
            (received_at, esp_param, event_param, remote_ip, user_agent,
             content_type, raw_headers, raw_body, http_method, query_string,
             created_at)
          VALUES
            (NOW(), :esp_param, :event_param, :remote_ip, :user_agent,
             :content_type, :raw_headers, :raw_body, :http_method, :query_string,
             NOW())
          RETURNING id
        SQL
          esp_param:    esp_param,
          event_param:  event_param,
          remote_ip:    request.remote_ip.to_s,
          user_agent:   request.user_agent.to_s,
          content_type: request.content_type.to_s,
          raw_headers:  raw_headers,
          raw_body:     raw_body,
          http_method:  request.method.to_s,
          query_string: request.query_string.to_s,
        )
        raw_log_id = ids.first
      rescue => e
        Rails.logger.error("[#{::EspWebhooks::PLUGIN_NAME}] raw_log insert failed: #{e.class}: #{e.message}")
      end

      # --- Parse and insert structured events (recognized ESPs only) --------
      esp_key = ::EspWebhooks.normalize_esp(esp_param)
      if esp_key.present? && ::EspWebhooks::RECOGNIZED_ESPS.include?(esp_key)
        begin
          parsed_events = ::EspWebhooks::Parsers.parse(
            esp_key,
            raw_body,
            request.content_type.to_s,
          )

          if parsed_events.present?
            parsed_events.each do |ev|
              DB.exec(<<~SQL,
                INSERT INTO esp_webhook_events
                  (raw_log_id, received_at, esp, esp_param, event_param,
                   event_type, raw_event_type, recipient_email, sender_email,
                   message_id, subject, bounce_class, bounce_reason, severity,
                   raw_event_json, created_at)
                VALUES
                  (:raw_log_id, NOW(), :esp, :esp_param, :event_param,
                   :event_type, :raw_event_type, :recipient_email, :sender_email,
                   :message_id, :subject, :bounce_class, :bounce_reason, :severity,
                   :raw_event_json, NOW())
              SQL
                raw_log_id:      raw_log_id,
                esp:             esp_key,
                esp_param:       esp_param,
                event_param:     event_param,
                event_type:      ev[:event_type],
                raw_event_type:  ev[:raw_event_type],
                recipient_email: ev[:recipient_email].to_s[0, 255],
                sender_email:    ev[:sender_email].to_s[0, 255],
                message_id:      ev[:message_id].to_s[0, 512],
                subject:         ev[:subject].to_s[0, 1000],
                bounce_class:    ev[:bounce_class].to_s[0, 255],
                bounce_reason:   ev[:bounce_reason].to_s,
                severity:        ev[:severity].to_s[0, 64],
                raw_event_json:  ev[:raw_event_json].to_s,
              )
            end
          end
        rescue => e
          Rails.logger.error("[#{::EspWebhooks::PLUGIN_NAME}] event parse/insert failed: #{e.class}: #{e.message}")
        end
      end

      render plain: "ok", status: 200
    rescue => e
      Rails.logger.error("[#{::EspWebhooks::PLUGIN_NAME}] controller error: #{e.class}: #{e.message}")
      render plain: "error", status: 500
    end

    def options_handler
      response.status = 204
      self.response_body = ""
    end
  end

  # ---------------------------------------------------------------------------
  # Routes
  # ---------------------------------------------------------------------------

  EspWebhooks::Engine.routes.draw do
    post    "/" => "webhook#receive"
    options "/" => "webhook#options_handler"
  end

  Discourse::Application.routes.append do
    mount ::EspWebhooks::Engine, at: "/esp-webhook"
  end
end
