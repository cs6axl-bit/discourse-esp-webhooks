# frozen_string_literal: true

class CreateEspWebhookEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :esp_webhook_events do |t|
      t.bigint   :raw_log_id                       # FK to esp_webhook_raw_logs.id
      t.datetime :received_at,    null: false
      t.string   :esp,            limit: 64        # normalized ESP name
      t.string   :esp_param,      limit: 255       # raw value of ?esp= param
      t.string   :event_param,    limit: 255       # raw value of ?event= param
      t.string   :event_type,     limit: 64        # normalized: bounce/unsubscribe/complaint/unknown
      t.string   :raw_event_type, limit: 255       # original event label from ESP
      t.string   :recipient_email, limit: 255
      t.string   :sender_email,    limit: 255
      t.string   :message_id,      limit: 512
      t.string   :subject,         limit: 1000
      t.string   :bounce_class,    limit: 255
      t.text     :bounce_reason
      t.string   :severity,        limit: 64
      t.text     :raw_event_json
      t.datetime :created_at,      null: false
    end

    add_index :esp_webhook_events, :received_at
    add_index :esp_webhook_events, :raw_log_id
    add_index :esp_webhook_events, :esp
    add_index :esp_webhook_events, :event_type
    add_index :esp_webhook_events, :recipient_email
  end
end
