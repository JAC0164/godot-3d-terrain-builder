import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// One self-contained HTML file (scripts and styles inlined), opened by
// double-click from the plugin folder: no server, no network.
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  build: { outDir: "dist", emptyOutDir: true },
  test: { environment: "node" },
});
