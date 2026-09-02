import type { NextConfig } from "next";
import path from "path";

const nextConfig: NextConfig = {
  // No external env vars required at build time.
  // DATABASE_URL is only read at runtime (in API routes via lib/db.ts).
  // PUSH_SECRET and VIEW_PASSWORD are also runtime-only.

  // Pin the tracing root to this web/ directory so Next.js does not walk up
  // to the monorepo root or a parent lockfile and emit a workspace warning.
  output: undefined,
  outputFileTracingRoot: path.join(__dirname),
};

export default nextConfig;
