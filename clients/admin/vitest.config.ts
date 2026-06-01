import path from "path"
import { defineConfig } from "vitest/config"
import react from "@vitejs/plugin-react"

// Test-only config. Mirrors vite.config.ts's react plugin + "@" alias, but uses
// the jsdom environment and skips CSS/tailwind processing (not needed for tests).
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "./src") },
  },
  test: {
    environment: "jsdom",
    globals: true,
    css: false,
    setupFiles: "./src/test/setup.ts",
    include: ["src/**/*.{test,spec}.{ts,tsx}"],
  },
})
