// Lint config for the Cloud Functions package (run via `npm run lint`, and in
// CI's functions job). Recommended TypeScript rules only — formatting is left
// to the editor, and `tsc --noEmit`-grade type errors are the build step's job.
module.exports = {
  root: true,
  env: { es2021: true, node: true },
  parser: "@typescript-eslint/parser",
  parserOptions: { sourceType: "module" },
  plugins: ["@typescript-eslint"],
  extends: ["eslint:recommended", "plugin:@typescript-eslint/recommended"],
  ignorePatterns: ["lib/**", "node_modules/**"],
};
