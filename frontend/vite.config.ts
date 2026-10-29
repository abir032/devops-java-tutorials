import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
  },
  build: {
    // `npm run build` writes static files here; serve them with any web server (e.g. nginx).
    outDir: "dist",
  },
});
