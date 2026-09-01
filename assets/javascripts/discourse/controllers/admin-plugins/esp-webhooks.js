import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

const EVENT_TYPES = ["all", "bounce", "complaint", "unsubscribe", "unknown"];

function ymd(date) {
  return date.toISOString().slice(0, 10);
}

function withPct(rows, key) {
  const list = rows || [];
  const max = Math.max(1, ...list.map((r) => r[key] || 0));
  return list.map((r) => ({ ...r, pct: Math.round(((r[key] || 0) / max) * 100) }));
}

class ProviderActionRow {
  @tracked on_complaint = false;
  @tracked on_unsubscribe = false;
  @tracked on_hard_bounce = false;
  @tracked also_mark_email_bad = false;
  @tracked hard_bounce_threshold = 3;
  @tracked hard_bounce_window_days = 90;

  constructor(raw = {}) {
    this.esp = raw.esp;
    this.on_complaint = !!raw.on_complaint;
    this.on_unsubscribe = !!raw.on_unsubscribe;
    this.on_hard_bounce = !!raw.on_hard_bounce;
    this.also_mark_email_bad = !!raw.also_mark_email_bad;
    this.hard_bounce_threshold = raw.hard_bounce_threshold ?? 3;
    this.hard_bounce_window_days = raw.hard_bounce_window_days ?? 90;
  }

  toJSON() {
    return {
      esp: this.esp,
      on_complaint: this.on_complaint,
      on_unsubscribe: this.on_unsubscribe,
      on_hard_bounce: this.on_hard_bounce,
      also_mark_email_bad: this.also_mark_email_bad,
      hard_bounce_threshold: this.hard_bounce_threshold,
      hard_bounce_window_days: this.hard_bounce_window_days,
    };
  }
}

export default class AdminPluginsEspWebhooksController extends Controller {
  @tracked stats = null;
  @tracked events = [];
  @tracked eventsMeta = { page: 1, per_page: 50, total: 0, total_pages: 1 };
  @tracked from = "";
  @tracked to = "";
  @tracked eventType = "all";
  @tracked esp = "all";
  @tracked loading = false;
  @tracked copiedUrl = null;

  @tracked providerActions = [];
  @tracked savingActions = false;
  @tracked actionsNotice = null;

  eventTypeOptions = EVENT_TYPES;

  setup(model) {
    this.stats = model.stats;
    this.events = model.events?.events || [];
    this.eventsMeta = model.events?.meta || this.eventsMeta;
    this.from = model.from;
    this.to = model.to;
    this.eventType = model.stats?.filters?.event_type || "all";
    this.esp = model.stats?.filters?.esp || "all";
    this.providerActions = (model.providerActions?.provider_actions || []).map(
      (r) => new ProviderActionRow(r)
    );
  }

  get actionsEnabled() {
    return !!this.stats?.actions_enabled;
  }

  get recentActions() {
    return (this.stats?.recent_actions || []).map((r) => ({
      ...r,
      when: r.created_at
        ? r.created_at.replace("T", " ").replace("Z", "").slice(0, 16) + " UTC"
        : "",
    }));
  }

  get espOptions() {
    return ["all", ...(this.stats?.recognized_esps || [])];
  }

  get providerRows() {
    return withPct(this.stats?.by_provider, "count");
  }

  get eventTypeRows() {
    return withPct(this.stats?.by_event_type, "count");
  }

  get dayRows() {
    return withPct(this.stats?.by_day, "count");
  }

  get urlRows() {
    const ep = this.stats?.endpoints || {};
    return (this.stats?.recognized_esps || []).map((key) => ({
      key,
      url: ep[key],
    }));
  }

  get displayEvents() {
    return (this.events || []).map((r) => ({
      ...r,
      when: r.received_at
        ? r.received_at.replace("T", " ").replace("Z", "").slice(0, 16) + " UTC"
        : "",
    }));
  }

  get hasPrev() {
    return this.eventsMeta.page > 1;
  }

  get hasNext() {
    return this.eventsMeta.page < this.eventsMeta.total_pages;
  }

  get queryString() {
    const p = new URLSearchParams();
    if (this.from) {
      p.set("from", this.from);
    }
    if (this.to) {
      p.set("to", this.to);
    }
    if (this.eventType && this.eventType !== "all") {
      p.set("event_type", this.eventType);
    }
    if (this.esp && this.esp !== "all") {
      p.set("esp", this.esp);
    }
    return p.toString();
  }

  async loadPage(page) {
    this.loading = true;
    try {
      const qs = this.queryString;
      const [stats, events] = await Promise.all([
        ajax(`/admin/esp-webhooks/stats.json?${qs}`),
        ajax(`/admin/esp-webhooks/events.json?${qs}&page=${page}`),
      ]);
      this.stats = stats;
      this.events = events.events || [];
      this.eventsMeta = events.meta || this.eventsMeta;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  async loadEventsOnly(page) {
    this.loading = true;
    try {
      const events = await ajax(
        `/admin/esp-webhooks/events.json?${this.queryString}&page=${page}`
      );
      this.events = events.events || [];
      this.eventsMeta = events.meta || this.eventsMeta;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  @action
  applyFilters() {
    this.loadPage(1);
  }

  @action
  resetFilters() {
    const today = new Date();
    const from = new Date();
    from.setDate(from.getDate() - 30);
    this.from = ymd(from);
    this.to = ymd(today);
    this.eventType = "all";
    this.esp = "all";
    this.loadPage(1);
  }

  @action
  prevPage() {
    if (this.hasPrev) {
      this.loadEventsOnly(this.eventsMeta.page - 1);
    }
  }

  @action
  nextPage() {
    if (this.hasNext) {
      this.loadEventsOnly(this.eventsMeta.page + 1);
    }
  }

  @action
  updateFrom(event) {
    this.from = event.target.value;
  }

  @action
  updateTo(event) {
    this.to = event.target.value;
  }

  @action
  updateEventType(event) {
    this.eventType = event.target.value;
  }

  @action
  updateEsp(event) {
    this.esp = event.target.value;
  }

  @action
  async copyUrl(url) {
    try {
      await navigator.clipboard.writeText(url);
      this.copiedUrl = url;
      setTimeout(() => {
        if (this.copiedUrl === url) {
          this.copiedUrl = null;
        }
      }, 1500);
    } catch (e) {
      // clipboard unavailable - ignore
    }
  }

  @action
  async saveProviderActions() {
    this.savingActions = true;
    this.actionsNotice = null;
    try {
      const data = await ajax("/admin/esp-webhooks/provider-actions.json", {
        type: "PUT",
        data: {
          rows: JSON.stringify(this.providerActions.map((r) => r.toJSON())),
        },
      });
      this.providerActions = (data.provider_actions || []).map(
        (r) => new ProviderActionRow(r)
      );
      this.actionsNotice = "Saved.";
      setTimeout(() => {
        this.actionsNotice = null;
      }, 2000);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.savingActions = false;
    }
  }
}
