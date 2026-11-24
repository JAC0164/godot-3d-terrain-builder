// Copies the single-file build to the plugin folder root as map-editor.html.
import { copyFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const from = resolve(here, "../dist/index.html");
const to = resolve(here, "../../../map-editor.html");
copyFileSync(from, to);
console.log(`copied ${from} -> ${to}`);
