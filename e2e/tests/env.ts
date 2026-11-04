// The tests' inputs, all from the environment scripts/e2e-disposable.sh
// sets. Read inside the tests, never at import time, so `playwright test
// --list` (CI) needs none of them.
//
//   E2E_VAULT_URL            the disposable vault, e.g.
//                            https://disposable.vault.jasonrossmedia.com
//   E2E_EMAIL                this run's account, e2e-<run>@example.com
//   E2E_PASSWORD             its master password: made by the script, masked
//                            in the job log, never printed or shown in a
//                            report (see enterSecret in webvault.ts)
//   E2E_MARKER               this run's marker, in the item name and the
//                            failed login's address
//   E2E_CANARY               the notes canary (runbook §3.8)
//   E2E_ATTACHMENT_CANARY    the attachment's whole content
//   E2E_RESTORE_URL          the restored copy, https://localhost:<port>
//   E2E_RESTORE_SPKI         its throwaway certificate's SPKI pin

export function vaultUrl(): string {
  return process.env.E2E_VAULT_URL ?? 'https://disposable.vault.jasonrossmedia.com';
}

export function need(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is not set: run these tests through scripts/e2e-disposable.sh`);
  }
  return value;
}

export interface Run {
  email: string;
  password: string;
  marker: string;
  canary: string;
  attachmentCanary: string;
  itemName: string;
}

export function thisRun(): Run {
  const marker = need('E2E_MARKER');
  return {
    email: need('E2E_EMAIL'),
    password: need('E2E_PASSWORD'),
    marker,
    canary: need('E2E_CANARY'),
    attachmentCanary: need('E2E_ATTACHMENT_CANARY'),
    itemName: `e2e canary ${marker}`,
  };
}

// The attachment's file name, as the web vault lists it.
export const attachmentName = 'e2e-canary.txt';
