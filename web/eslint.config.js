import js from "@eslint/js";
import globals from "globals";
import { defineConfig, globalIgnores } from "eslint/config";
import eslintConfigPrettier from "eslint-config-prettier/flat";

export default defineConfig([
  globalIgnores([".zig-cache", "zig-out", "dist"]),
  {
    files: ["**/*.js"],
    plugins: { js },
    extends: ["js/recommended"],
    languageOptions: { globals: globals.browser },
  },
  {
    files: ["src/processor.js"],
    languageOptions: { globals: globals.audioWorklet },
  },
  eslintConfigPrettier,
]);
