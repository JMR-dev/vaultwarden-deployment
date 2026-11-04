// The disposable vault through an IAP tunnel to its :443, so Caddy sees an
// IAP source address and lets registration through (caddy/Caddyfile, note 3).
// The certificate is the real one: the browser maps the name to the local end
// of the tunnel, and the URL is unchanged, so it matches.
//
// One account per run. The tests depend on each other, in this order, and
// stop at the first failure.
import { expect, test } from '@playwright/test';
import { attachmentName, thisRun } from './env.ts';
import { logIn, logOut, masterPasswordField, enterSecret, openItem, register, step } from './webvault.ts';

test.describe.configure({ mode: 'serial' });

test('runbook §2.8: register this run\'s account through the tunnel', async ({ page }) => {
  const run = thisRun();
  await register(page, run.email, run.password);
});

test('runbook §2.8, §3.8, §3.10: log in, add the canary item and its attachment, log out', async ({ page }) => {
  const run = thisRun();
  await logIn(page, run.email, run.password);

  await step('add a login item with the canary in its notes', async () => {
    await page.getByRole('main').getByRole('button', { name: 'Add', exact: true }).click();
    await page.getByRole('menuitem', { name: 'Login' }).click();
    const add = page.getByRole('dialog', { name: 'Add login' });
    await add.getByRole('textbox', { name: /^Item name/ }).fill(run.itemName);
    await add.getByRole('textbox', { name: 'Notes' }).fill(run.canary);
    await add.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByRole('dialog', { name: 'View login' }).getByRole('heading', { name: run.itemName })).toBeVisible();
  });

  await step('attach a file (runbook §3.10: the WAF must not block it)', async () => {
    const view = page.getByRole('dialog', { name: 'View login' });
    await view.getByRole('button', { name: 'Edit' }).click();
    const edit = page.getByRole('dialog', { name: 'Edit login' });
    await edit.getByRole('button', { name: 'Attachments' }).click();
    const attach = page.getByRole('dialog', { name: 'Add attachment' });
    await attach.locator('input[type=file]').setInputFiles({
      name: attachmentName,
      mimeType: 'text/plain',
      buffer: Buffer.from(run.attachmentCanary),
    });
    // Two requests: the v2 call that registers the attachment, then the
    // encrypted file itself. Coraza runs DetectionOnly, so neither may be a
    // 403; any refusal fails here with its status.
    const uploads: { url: string; status: number }[] = [];
    page.on('response', (response) => {
      if (response.request().method() === 'POST' && /\/api\/ciphers\/[^/]+\/attachment\//.test(response.url())) {
        uploads.push({ url: new URL(response.url()).pathname, status: response.status() });
      }
    });
    await attach.getByRole('button', { name: 'Upload' }).click();
    await expect(attach).toBeHidden({ timeout: 120_000 });
    expect(uploads.length, 'attachment upload requests seen').toBeGreaterThanOrEqual(2);
    for (const upload of uploads) {
      expect(upload.status, `POST ${upload.url}`).not.toBe(403);
      expect(upload.status, `POST ${upload.url}`).toBeLessThan(400);
    }
    await edit.getByRole('button', { name: 'Cancel' }).click();
    await expect(
      page.getByRole('dialog', { name: 'View login' }).getByRole('button', { name: `Download ${attachmentName}` }),
    ).toBeVisible();
    await page.getByRole('dialog', { name: 'View login' }).getByRole('button', { name: 'Close' }).click();
  });

  await step('find the item again from the list', async () => {
    const view = await openItem(page, run.itemName);
    await expect(view.getByRole('textbox', { name: 'Note' })).toHaveValue(run.canary);
    await view.getByRole('button', { name: 'Close' }).click();
  });

  await logOut(page);
});

// The first of runbook §3.12's two lines that must never reach watchtower.
// (The second, a "password" in the username field, goes in by curl: the web
// vault refuses an address that isn't one before sending anything.)
test('runbook §3.12: fail a login with a made-up address', async ({ page }) => {
  const run = thisRun();
  await step('try nobody-<marker>@example.com', async () => {
    await page.goto('/#/login');
    await page.getByRole('textbox', { name: /^Email address/ }).fill(`nobody-${run.marker}@example.com`);
    await page.getByRole('button', { name: 'Continue' }).click();
    // Not this run's password: a made-up one for a made-up account.
    await enterSecret(masterPasswordField(page), `wrong-${run.marker}`);
    await page.getByRole('button', { name: 'Log in', exact: true }).click();
    await expect(page.getByText(/Invalid master password/)).toBeVisible();
  });
});
