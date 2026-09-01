import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

function ymd(date) {
  return date.toISOString().slice(0, 10);
}

export default class AdminPluginsEspWebhooksRoute extends Route {
  async model() {
    const to = new Date();
    const from = new Date();
    from.setDate(from.getDate() - 30);

    const qs = `from=${ymd(from)}&to=${ymd(to)}`;
    const [stats, events, providerActions] = await Promise.all([
      ajax(`/admin/esp-webhooks/stats.json?${qs}`),
      ajax(`/admin/esp-webhooks/events.json?${qs}&page=1`),
      ajax(`/admin/esp-webhooks/provider-actions.json`),
    ]);

    return { stats, events, providerActions, from: ymd(from), to: ymd(to) };
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.setup(model);
  }
}
