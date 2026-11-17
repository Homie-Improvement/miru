import { defineConfig, mergeConfig } from "vitest/config";

import viteConfig from "./vite.config.mts";

// Reuses the app's Vite config so tests resolve the same import aliases as
// the build. vite-plugin-ruby moves the root to app/javascript, so test
// paths below are relative to that directory.
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: "jsdom",
      include: ["src/**/__tests__/**/*.test.{ts,tsx}"],
      restoreMocks: true,
    },
  })
);
