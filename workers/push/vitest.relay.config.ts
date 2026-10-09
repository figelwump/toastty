import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineProject } from "vitest/config";

export default defineProject({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.relay.jsonc", environment: "test" } })],
  test: { include: ["test/relay/**/*.test.ts"] }
});
