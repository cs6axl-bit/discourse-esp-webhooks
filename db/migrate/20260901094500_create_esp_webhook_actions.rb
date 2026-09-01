# frozen_string_literal: true

class CreateEspWebhookActions < ActiveRecord::Migration[7.0]
  def change
    create_table :esp_webhook_provider_actions do |t|
      t.string  :esp,                     limit: 64,  null: false
      t.boolean :on_complaint,            null: false, default: false
      t.boolean :on_unsubscribe,          null: false, default: false
      t.boolean :on_hard_bounce,          null: false, default: false
      t.integer :hard_bounce_threshold,   null: false, default: 3
      t.integer :hard_bounce_window_days, null: false, default: 90
      t.boolean :also_mark_email_bad,     null: false, default: false
      t.timestamps null: false
    end
    add_index :esp_webhook_provider_actions, :esp, unique: true

    create_table :esp_webhook_actions do |t|
      t.string   :esp,               limit: 64
      t.bigint   :event_id
      t.bigint   :user_id
      t.string   :recipient_email,   limit: 255
      t.string   :reason,            limit: 32,  null: false
      t.string   :action,            limit: 64,  null: false
      t.integer  :hard_bounce_count
      t.jsonb    :details,           null: false, default: {}
      t.datetime :created_at,        null: false
    end
    add_index :esp_webhook_actions, %i[user_id reason]
    add_index :esp_webhook_actions, :recipient_email
    add_index :esp_webhook_actions, :esp
    add_index :esp_webhook_actions, :created_at
  end
end
