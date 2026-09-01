# discourse-esp-webhooks

Receives and **logs** ESP webhook / postback events (bounces, spam complaints,
unsubscribes) from SparkPost, Elastic Email, ReachMail, InboxRoad and Mailgun.
Logging only — nothing acts on Discourse (no email suppression / unsubscribe).

## Install

Drop in `discourse/plugins/`, rebuild, then enable **`esp_webhooks_enabled`** in
Admin → Settings → Plugins. While it's off, the receiver returns 404.

## Webhook endpoint

One endpoint, `esp=` selects the parser:

```
POST https://<your-forum>/esp-webhook?esp=<key>
```

`<key>` ∈ `sparkpost` · `elasticemail` · `reachmail` · `inboxroad` · `mailgun`.
`&event=<label>` is optional (stored, not required). No auth / signature check.

The exact URLs (with your forum's base URL) and copy buttons are on the admin
page.

## Admin page

**Admin → Plugins → ESP Webhooks** (`/admin/plugins/esp-webhooks`):

- the per-provider webhook URLs + receiver on/off state
- statistics on received events, filterable by **date range**, **event type**
  (bounce / complaint / unsubscribe / unknown) and **provider**:
  - stat cards (parsed events, bounces, complaints, unsubscribes, unknown, raw
    hits, unparsed raw)
  - breakdown by provider / event type / day (bars)
  - top bounce classes with a sample reason
  - paginated recent-events table

JSON behind it: `GET /admin/esp-webhooks/stats.json` and
`GET /admin/esp-webhooks/events.json` (staff only), params `from`, `to`,
`event_type`, `esp`, `page`.

## Automated actions

On the admin page, the **Automated actions** panel configures, **per provider ×
per event type**, whether an incoming event acts on the matching Discourse user.
Everything is **off by default**; `esp_webhooks_actions_enabled` (site setting,
default on) is a global kill switch.

Current action: **disable digest emails** for that user —
`user_options.email_digests = false`, `digest_after_minutes = 0`.

| event | when it fires |
|---|---|
| spam complaint | first complaint for that user (acts once, ever) |
| unsubscribe | first unsubscribe for that user (acts once, ever) |
| hard bounce | when hard bounces for that address within the **window (days)** reach the **threshold**; re-acts only after another full window |

"Hard bounce" is a heuristic over `severity` / `bounce_class` / `raw_event_type` /
`bounce_reason` (permanent / `5.x` / SparkPost class 10·90 / `out_of_band` / …).
Soft bounces never count.

Per-provider, hard bounce has an extra optional toggle **Also mark email bad** —
raises the user's `user_stats.bounce_score` past `bounce_score_threshold` so
Discourse stops emailing the address entirely (default off).

Addresses with no matching Discourse user are logged but ignored. Every action is
recorded in **`esp_webhook_actions`** (also the "already acted" guard) and shown
in the panel's *Recent actions* table.

JSON: `GET`/`PUT /admin/esp-webhooks/provider-actions.json` (admin).

## Tables

- **`esp_webhook_raw_logs`** — every POST, verbatim (headers, body, query string).
  Written even for unrecognized `esp` values or unparseable bodies.
- **`esp_webhook_events`** — parsed rows for recognized providers: normalized
  `event_type`, `raw_event_type`, `recipient_email`, `message_id`, `subject`,
  `bounce_class`, `bounce_reason`, `severity`, `raw_event_json`, `raw_log_id`.
- **`esp_webhook_provider_actions`** — per-provider action config (toggles,
  `hard_bounce_threshold`, `hard_bounce_window_days`, `also_mark_email_bad`).
- **`esp_webhook_actions`** — audit log of actions taken (`esp`, `event_id`,
  `user_id`, `recipient_email`, `reason`, `action`, `hard_bounce_count`).

"Unparsed raw" on the dashboard = raw-log rows with no child `esp_webhook_events`
row (unknown provider, or a payload shape the parser didn't recognise — inspect
`raw_body`).

## Quick test

```bash
curl -X POST "https://<your-forum>/esp-webhook?esp=mailgun" \
  -H "Content-Type: application/json" \
  -d '{"event-data":{"event":"failed","severity":"permanent","recipient":"x@y.com","delivery-status":{"bounce-type":"hard","message":"550 no such user"}}}'
# -> ok
```

Then reload the admin page (widen the date filter if needed).
