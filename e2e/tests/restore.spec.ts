// The restore drill's last step (runbook/restore-drill.md, step 5): the
// latest backup, restored on vault-disposable and served by a temporary
// Vaultwarden on its 127.0.0.1, must let this run's account log in and still
// hold the canary item and its attachment.
//
// That server has a throwaway self-signed certificate (the web vault needs a
// secure origin). Rather than turning certificate checks off, the browser
// trusts that one key: Chromium's --ignore-certificate-errors-spki-list with
// the pin the script read from the host over pinned SSH. The browser is
// launched here, not in playwright.config.ts, so the pin stays out of the
// reports' copy of the config.
import { chromium, expect, test } from '@playwright/test';
import { attachmentName, need, thisRun } from './env.ts';
import { logIn, logOut, openItem, step } from './webvault.ts';
import { readFile } from 'node:fs/promises';

test('restore drill: log in to the restored copy and open the canary item and its attachment', async ({}, testInfo) => {
  const run = thisRun();
  const browser = await chromium.launch({
    args: [`--ignore-certificate-errors-spki-list=${need('E2E_RESTORE_SPKI')}`],
  });
  const context = await browser.newContext({ baseURL: need('E2E_RESTORE_URL'), acceptDownloads: true });
  const page = await context.newPage();
  try {
    await logIn(page, run.email, run.password);
    const view = await openItem(page, run.itemName);
    await step('the notes still hold the canary', async () => {
      await expect(view.getByRole('textbox', { name: 'Note' })).toHaveValue(run.canary);
    });
    await step('the attachment downloads and decrypts to what was uploaded', async () => {
      const [download] = await Promise.all([
        page.waitForEvent('download'),
        view.getByRole('button', { name: `Download ${attachmentName}` }).click(),
      ]);
      expect(download.suggestedFilename()).toBe(attachmentName);
      expect(await readFile(await download.path(), 'utf8')).toBe(run.attachmentCanary);
    });
    await view.getByRole('button', { name: 'Close' }).click();
    await logOut(page);
  } catch (error) {
    // This browser isn't the fixture's, so take its failure screenshot here.
    const shot = testInfo.outputPath('restore-failure.png');
    await page.screenshot({ path: shot }).then(
      () => testInfo.attach('screenshot', { path: shot, contentType: 'image/png' }),
      () => undefined,
    );
    throw error;
  } finally {
    await context.close();
    await browser.close();
  }
});
