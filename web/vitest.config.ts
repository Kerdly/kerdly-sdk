import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "jsdom",
    // An https page on a registrable domain, like a production landing page.
    environmentOptions: { jsdom: { url: "https://acme-app.com/" } },
    // Keeps every test off the network (the IPv6 lookup calls fetch at init).
    setupFiles: ["test/setup.ts"],
    restoreMocks: true,
    unstubGlobals: true,
  },
});
