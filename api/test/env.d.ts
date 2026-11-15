import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      TEST_MIGRATIONS: D1Migration[];
    }
    // Tipizza `exports.default` nei test con il modulo principale del Worker.
    interface GlobalProps {
      mainModule: typeof import("../src/index");
    }
  }
}
