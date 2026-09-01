export default {
  resource: "admin.adminPlugins",
  path: "/plugins",

  map() {
    this.route("esp-webhooks", { path: "esp-webhooks" });
  },
};
