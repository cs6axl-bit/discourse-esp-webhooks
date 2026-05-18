# frozen_string_literal: true

class CreateEspWebhookRawLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :esp_webhook_raw_logs do |t|
      t.datetime :received_at,   null: false
      t.string   :esp_param,     limit: 255
      t.string   :event_param,   limit: 255
      t.string   :remote_ip,     limit: 45   # IPv6-safe
      t.text     :user_agent
      t.string   :content_type,  limit: 255
      t.text     :raw_headers
      t.text     :raw_body
      t.string   :http_method,   limit: 16
      t.text     :query_string
      t.datetime :created_at,    null: false
    end

    add_index :esp_webhook_raw_logs, :received_at
    add_index :esp_webhook_raw_logs, :esp_param
  end
end
