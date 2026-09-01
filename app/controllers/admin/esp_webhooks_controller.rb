# frozen_string_literal: true

module Admin
  # Read-only admin dashboard for the ESP webhook receiver:
  #   * the webhook URL to paste into each ESP panel
  #   * statistics on received events, filterable by date range / event type / provider
  #
  # Same plugin-admin pattern as discourse-digest-campaigns
  # (Admin::AdminController + render_json_dump + StaffConstraint route).
  class EspWebhooksController < Admin::AdminController
    requires_plugin ::EspWebhooks::PLUGIN_NAME

    EVENTS_PER_PAGE = 50

    # GET /admin/esp-webhooks/stats.json
    def stats
      f = event_filter
      w = f[:where]
      b = f[:binds]
      rf = raw_filter

      events_total =
        DB.query_single("SELECT COUNT(*) FROM esp_webhook_events e WHERE #{w}", b).first.to_i

      raw_total =
        DB.query_single("SELECT COUNT(*) FROM esp_webhook_raw_logs r WHERE #{rf[:where]}", rf[:binds]).first.to_i

      unparsed_total =
        DB.query_single(<<~SQL, rf[:binds]).first.to_i
          SELECT COUNT(*)
          FROM esp_webhook_raw_logs r
          WHERE #{rf[:where]}
            AND NOT EXISTS (SELECT 1 FROM esp_webhook_events e WHERE e.raw_log_id = r.id)
        SQL

      by_provider =
        DB.query(<<~SQL, b).map { |r| { esp: r.esp.presence || "(unknown)", count: r.c.to_i } }
          SELECT e.esp AS esp, COUNT(*) AS c
          FROM esp_webhook_events e
          WHERE #{w}
          GROUP BY e.esp
          ORDER BY c DESC
        SQL

      by_event_type =
        DB.query(<<~SQL, b).map { |r| { event_type: r.event_type.presence || "(none)", count: r.c.to_i } }
          SELECT e.event_type AS event_type, COUNT(*) AS c
          FROM esp_webhook_events e
          WHERE #{w}
          GROUP BY e.event_type
          ORDER BY c DESC
        SQL

      by_day =
        DB.query(<<~SQL, b).map { |r| { day: r.d.to_s, count: r.c.to_i } }
          SELECT e.received_at::date AS d, COUNT(*) AS c
          FROM esp_webhook_events e
          WHERE #{w}
          GROUP BY d
          ORDER BY d
        SQL

      top_bounce_classes =
        DB.query(<<~SQL, b).map { |r| { bounce_class: r.bounce_class, count: r.c.to_i, sample: r.sample } }
          SELECT COALESCE(NULLIF(e.bounce_class, ''), '(none)') AS bounce_class,
                 COUNT(*) AS c,
                 MAX(e.bounce_reason) AS sample
          FROM esp_webhook_events e
          WHERE #{w} AND e.event_type = 'bounce'
          GROUP BY 1
          ORDER BY c DESC
          LIMIT 10
        SQL

      recent =
        DB.query(<<~SQL, b).map { |r| event_row(r) }
          SELECT e.id, e.received_at, e.esp, e.event_type, e.raw_event_type,
                 e.recipient_email, e.sender_email, e.subject, e.bounce_class,
                 e.bounce_reason, e.severity, e.message_id
          FROM esp_webhook_events e
          WHERE #{w}
          ORDER BY e.received_at DESC, e.id DESC
          LIMIT 20
        SQL

      count_of = ->(type) { by_event_type.find { |x| x[:event_type] == type }&.fetch(:count).to_i }

      af = actions_filter
      actions_total =
        DB.query_single("SELECT COUNT(*) FROM esp_webhook_actions a WHERE #{af[:where]}", af[:binds]).first.to_i

      recent_actions =
        DB.query(<<~SQL, af[:binds]).map { |r| action_row(r) }
          SELECT a.id, a.created_at, a.esp, a.recipient_email, a.reason,
                 a.action, a.hard_bounce_count, a.user_id
          FROM esp_webhook_actions a
          WHERE #{af[:where]}
          ORDER BY a.created_at DESC, a.id DESC
          LIMIT 20
        SQL

      render_json_dump(
        enabled: SiteSetting.esp_webhooks_enabled,
        actions_enabled: SiteSetting.esp_webhooks_actions_enabled,
        recognized_esps: ::EspWebhooks::RECOGNIZED_ESPS,
        endpoints: endpoints,
        filters: f[:echo],
        totals: {
          events: events_total,
          bounce: count_of.call("bounce"),
          complaint: count_of.call("complaint"),
          unsubscribe: count_of.call("unsubscribe"),
          unknown: count_of.call("unknown"),
          raw_hits: raw_total,
          unparsed_raw_hits: unparsed_total,
          actions: actions_total,
        },
        by_provider: by_provider,
        by_event_type: by_event_type,
        by_day: by_day,
        top_bounce_classes: top_bounce_classes,
        recent: recent,
        recent_actions: recent_actions,
      )
    end

    # GET /admin/esp-webhooks/provider-actions.json
    def provider_actions
      render_json_dump(provider_actions: ::EspWebhooks::RECOGNIZED_ESPS.map { |esp| provider_action_row(esp) })
    end

    # PUT /admin/esp-webhooks/provider-actions.json
    def update_provider_actions
      rows =
        case params[:rows]
        when String then (JSON.parse(params[:rows]) rescue [])
        when Array then params[:rows]
        else []
        end

      Array(rows).each do |raw|
        h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
        next unless h.is_a?(Hash)
        esp = ::EspWebhooks.normalize_esp(h["esp"] || h[:esp])
        next unless ::EspWebhooks::RECOGNIZED_ESPS.include?(esp)

        rec = ::EspWebhooks::ProviderAction.find_or_initialize_by(esp: esp)
        rec.on_complaint            = truthy(h["on_complaint"] || h[:on_complaint])
        rec.on_unsubscribe          = truthy(h["on_unsubscribe"] || h[:on_unsubscribe])
        rec.on_hard_bounce          = truthy(h["on_hard_bounce"] || h[:on_hard_bounce])
        rec.also_mark_email_bad     = truthy(h["also_mark_email_bad"] || h[:also_mark_email_bad])
        rec.hard_bounce_threshold   = (h["hard_bounce_threshold"] || h[:hard_bounce_threshold]).to_i.clamp(1, 50)
        rec.hard_bounce_window_days = (h["hard_bounce_window_days"] || h[:hard_bounce_window_days]).to_i.clamp(1, 365)
        rec.save!
      end

      render_json_dump(provider_actions: ::EspWebhooks::RECOGNIZED_ESPS.map { |esp| provider_action_row(esp) })
    end

    # GET /admin/esp-webhooks/events.json
    def events
      f = event_filter
      page = params[:page].to_i
      page = 1 if page < 1
      per = EVENTS_PER_PAGE
      binds = f[:binds].merge(lim: per, off: (page - 1) * per)

      total =
        DB.query_single("SELECT COUNT(*) FROM esp_webhook_events e WHERE #{f[:where]}", f[:binds]).first.to_i

      rows =
        DB.query(<<~SQL, binds).map { |r| event_row(r) }
          SELECT e.id, e.received_at, e.esp, e.event_type, e.raw_event_type,
                 e.recipient_email, e.sender_email, e.subject, e.bounce_class,
                 e.bounce_reason, e.severity, e.message_id
          FROM esp_webhook_events e
          WHERE #{f[:where]}
          ORDER BY e.received_at DESC, e.id DESC
          LIMIT :lim OFFSET :off
        SQL

      render_json_dump(
        events: rows,
        meta: {
          page: page,
          per_page: per,
          total: total,
          total_pages: [(total.to_f / per).ceil, 1].max,
        },
      )
    end

    private

    def endpoints
      base = "#{Discourse.base_url}/esp-webhook"
      map = { "base" => base }
      ::EspWebhooks::RECOGNIZED_ESPS.each { |key| map[key] = "#{base}?esp=#{key}" }
      map
    end

    # Shared WHERE + binds for esp_webhook_events (alias `e`).
    def event_filter
      where = ["1=1"]
      binds = {}

      if (from = boundary_time(params[:from], :beginning))
        where << "e.received_at >= :from"
        binds[:from] = from
      end
      if (to = boundary_time(params[:to], :end))
        where << "e.received_at <= :to"
        binds[:to] = to
      end

      event_type = params[:event_type].to_s.strip.downcase
      if event_type.present? && event_type != "all"
        where << "e.event_type = :event_type"
        binds[:event_type] = event_type
      end

      esp = ::EspWebhooks.normalize_esp(params[:esp])
      if params[:esp].to_s.strip.downcase != "all" && esp.present?
        where << "e.esp = :esp"
        binds[:esp] = esp
      end

      {
        where: where.join(" AND "),
        binds: binds,
        echo: {
          from: params[:from].to_s,
          to: params[:to].to_s,
          event_type: event_type.presence || "all",
          esp: params[:esp].to_s.strip.presence || "all",
        },
      }
    end

    # Raw-log filter: only date + provider apply (raw logs have no event_type).
    def raw_filter
      where = ["1=1"]
      binds = {}

      if (from = boundary_time(params[:from], :beginning))
        where << "r.received_at >= :from"
        binds[:from] = from
      end
      if (to = boundary_time(params[:to], :end))
        where << "r.received_at <= :to"
        binds[:to] = to
      end

      esp = ::EspWebhooks.normalize_esp(params[:esp])
      if params[:esp].to_s.strip.downcase != "all" && esp.present?
        where << "regexp_replace(lower(coalesce(r.esp_param, '')), '[^a-z0-9]', '', 'g') = :esp"
        binds[:esp] = esp
      end

      { where: where.join(" AND "), binds: binds }
    end

    def boundary_time(raw, edge)
      s = raw.to_s.strip
      return nil if s.empty?
      t = Time.zone.parse(s)
      return nil unless t
      edge == :end ? t.end_of_day : t.beginning_of_day
    rescue ArgumentError
      nil
    end

    def event_row(r)
      {
        id: r.id,
        received_at: r.received_at&.iso8601,
        esp: r.esp,
        event_type: r.event_type,
        raw_event_type: r.raw_event_type,
        recipient_email: r.recipient_email,
        sender_email: r.sender_email,
        subject: r.subject,
        bounce_class: r.bounce_class,
        bounce_reason: r.bounce_reason,
        severity: r.severity,
        message_id: r.message_id,
      }
    end

    # Filter for esp_webhook_actions (alias `a`) — date + provider only.
    def actions_filter
      where = ["1=1"]
      binds = {}

      if (from = boundary_time(params[:from], :beginning))
        where << "a.created_at >= :from"
        binds[:from] = from
      end
      if (to = boundary_time(params[:to], :end))
        where << "a.created_at <= :to"
        binds[:to] = to
      end

      esp = ::EspWebhooks.normalize_esp(params[:esp])
      if params[:esp].to_s.strip.downcase != "all" && esp.present?
        where << "a.esp = :esp"
        binds[:esp] = esp
      end

      { where: where.join(" AND "), binds: binds }
    end

    def action_row(r)
      {
        id: r.id,
        created_at: r.created_at&.iso8601,
        esp: r.esp,
        recipient_email: r.recipient_email,
        reason: r.reason,
        action: r.action,
        hard_bounce_count: r.hard_bounce_count,
        user_id: r.user_id,
      }
    end

    def provider_action_row(esp)
      rec = ::EspWebhooks::ProviderAction.find_or_initialize_by(esp: esp)
      {
        esp: esp,
        on_complaint: !!rec.on_complaint,
        on_unsubscribe: !!rec.on_unsubscribe,
        on_hard_bounce: !!rec.on_hard_bounce,
        hard_bounce_threshold: rec.hard_bounce_threshold || 3,
        hard_bounce_window_days: rec.hard_bounce_window_days || 90,
        also_mark_email_bad: !!rec.also_mark_email_bad,
      }
    end

    def truthy(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end
  end
end
