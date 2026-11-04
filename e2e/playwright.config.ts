// Browser checks of the disposable stack. scripts/e2e-disposable.sh runs
// them in two stages, one project each, and sets every E2E_* variable; see
// tests/env.ts for what each holds.
//
//   vault    through an IAP tunnel to the VM's :443, bound on this machine's
//            127.0.0.1:443: register, log in, add the canary item and its
//            attachment, log out, and fail a login (runbook §2.8, §3.10, §3.12).
//   restore  the restore drill: log in to a temporary Vaultwarden serving the
//            restored backup, reached through `ssh -L` (tests/restore.spec.ts).
//
// What this never does: record a trace or a video (both would hold what was
// typed, and the repo is public), or retry (a retry would register twice and
// hide a flaky stack). Failures keep a screenshot, and the HTML report is
// uploaded with it. Before that, the script deletes every error-context.md
// (Playwright puts a snapshot of the page in it, typed passwords included)
// and checks what's left for the run's password with scan-secret.mjs.
import { defineConfig } from '@playwright/test';
import { vaultUrl } from './tests/env.ts';

const stage = process.env.E2E_STAGE ?? 'dev';
const vaultHost = new URL(vaultUrl()).hostname;

// The browser alone resolves the vault's name to the tunnel. Every other
// request the script makes (curl) resolves it publicly, so a "public" check
// can't quietly go through the tunnel and arrive from IAP's range.
const vaultArgs = [`--host-resolver-rules=MAP ${vaultHost} 127.0.0.1`];
// Dev only, never set in CI: pin a local test server's self-signed key.
if (process.env.E2E_VAULT_SPKI) {
  vaultArgs.push(`--ignore-certificate-errors-spki-list=${process.env.E2E_VAULT_SPKI}`);
}

export default defineConfig({
  testDir: './tests',
  forbidOnly: true,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  // An IAP tunnel and a 2 GB VM: slow is normal, hung is not.
  timeout: 5 * 60_000,
  expect: { timeout: 30_000 },
  outputDir: `./test-results/${stage}`,
  reporter: [['list'], ['html', { open: 'never', outputFolder: `./reports/${stage}` }]],
  use: {
    trace: 'off',
    video: 'off',
    screenshot: 'only-on-failure',
    actionTimeout: 60_000,
    navigationTimeout: 120_000,
    browserName: 'chromium',
  },
  projects: [
    {
      name: 'vault',
      testMatch: 'vault.spec.ts',
      use: { baseURL: vaultUrl(), launchOptions: { args: vaultArgs } },
    },
    {
      // The browser is launched in the test itself, with the restored
      // server's key pinned (restore.spec.ts says why it isn't here).
      name: 'restore',
      testMatch: 'restore.spec.ts',
    },
  ],
});
