import { createRequestHandler } from "react-router";

declare module "react-router" {
  export interface AppLoadContext {
    cloudflare: {
      env: Env;
      ctx: ExecutionContext;
    };
  }
}

// @ts-expect-error resolved by Vite in dev, by wrangler alias in production
import * as serverBuild from "virtual:react-router/server-build";

const requestHandler = createRequestHandler(serverBuild, "production");

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    return requestHandler(request, {
      cloudflare: { env, ctx },
    });
  },
} satisfies ExportedHandler<Env>;
