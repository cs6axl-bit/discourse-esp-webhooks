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

## Tables

- **`esp_webhook_raw_logs`** — every POST, verbatim (headers, body, query string).
  Written even for unrecognized `esp` values or unparseable bodies.
- **`esp_webhook_events`** — parsed rows for recognized providers: normalized
  `event_type`, `raw_event_type`, `recipient_email`, `message_id`, `subject`,
  `bounce_class`, `bounce_reason`, `severity`, `raw_event_json`, `raw_log_id`.

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
