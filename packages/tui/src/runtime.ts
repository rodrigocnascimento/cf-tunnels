// Production builds have no React DevTools dependency; Ink's optional probe is
// development-only and must not run in the self-contained runtime.
process.env.DEV = "false";
await import("./index.js");

export {};
