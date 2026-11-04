// The web vault's flows, as upstream's client (the one vaultwarden/server:latest
// ships) draws them. Roles and labels only; found against Vaultwarden 1.37.5
// with Vaultwarden Web 2026.10.1.
import { expect, test, type Locator, type Page } from '@playwright/test';

// step runs one named stage and puts its name in front of any error, so a
// failure in the job log says which step broke, not just which line.
export async function step<T>(name: string, body: () => Promise<T>): Promise<T> {
  return test.step(name, async () => {
    try {
      return await body();
    } catch (error) {
      if (error instanceof Error) {
        error.message = `[${name}] ${error.message}`;
      }
      throw error;
    }
  });
}

// enterSecret types a secret without it reaching a report. Playwright titles
// fill() and type() steps with the value itself (`Fill "<value>"`), and the
// HTML report shows those titles; an evaluate step is titled "Evaluate", with
// no arguments. The web vault's inputs are Angular reactive-form controls,
// which pick the value up from the input event.
export async function enterSecret(field: Locator, value: string): Promise<void> {
  await field.evaluate((element, secret) => {
    const input = element as HTMLInputElement;
    input.focus();
    input.value = secret;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    input.blur();
  }, value);
}

export function masterPasswordField(page: Page): Locator {
  // "Master password * (required)", not the hint field below it.
  return page.getByRole('textbox', { name: /^Master password \*/ });
}

// register creates the account through /#/signup. With no SMTP, Vaultwarden
// skips the verification mail and the client goes straight on to the
// password step.
export async function register(page: Page, email: string, password: string): Promise<void> {
  await step('open the signup page', async () => {
    await page.goto('/#/signup');
    await expect(page.getByRole('heading', { name: 'Create account' })).toBeVisible();
  });
  await step('enter the address and name', async () => {
    await page.getByRole('textbox', { name: /^Email address/ }).fill(email);
    await page.getByRole('textbox', { name: 'Name', exact: true }).fill('e2e');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('heading', { name: 'Set a strong password' })).toBeVisible();
  });
  await step('set the master password (not shown)', async () => {
    await enterSecret(masterPasswordField(page), password);
    await enterSecret(page.getByRole('textbox', { name: /^Confirm master password/ }), password);
    // The breach check sends a hash prefix of the password to
    // api.pwnedpasswords.com: an outside dependency the test doesn't need.
    await page.getByRole('checkbox', { name: 'Check known data breaches for this password' }).uncheck();
  });
  await step('create the account', async () => {
    await page.getByRole('button', { name: 'Create account' }).click();
    await expect(page.getByText('Your new account has been created!')).toBeVisible();
  });
}

// logIn signs in and waits for the vault itself, past the onboarding screens.
export async function logIn(page: Page, email: string, password: string): Promise<void> {
  await step('open the login page', async () => {
    await page.goto('/#/login');
    await page.getByRole('textbox', { name: /^Email address/ }).fill(email);
    await page.getByRole('button', { name: 'Continue' }).click();
  });
  await step('enter the master password (not shown)', async () => {
    await enterSecret(masterPasswordField(page), password);
    await page.getByRole('button', { name: 'Log in', exact: true }).click();
  });
  await step('reach the vault', () => dismissOnboarding(page));
}

// dismissOnboarding clicks through the screens a fresh browser gets after
// logging in (the extension pitch, its "are you sure", the tour) until the
// vault is showing with no dialog over it. Their order and number vary, so it
// takes whichever is up.
async function dismissOnboarding(page: Page): Promise<void> {
  const vault = page.getByRole('heading', { name: 'All vaults', level: 1 });
  const onboarding: Locator[] = [
    page.getByRole('button', { name: 'Add it later' }),
    page.getByRole('link', { name: 'Skip to web app' }),
    page.getByRole('dialog').getByRole('button', { name: 'Skip', exact: true }),
  ];
  const anyScreen = onboarding.reduce((all, screen) => all.or(screen), vault);
  for (let round = 0; round < 10; round++) {
    await expect(anyScreen.first()).toBeVisible({ timeout: 120_000 });
    let clicked = false;
    for (const screen of onboarding) {
      if (await screen.isVisible()) {
        await screen.click();
        clicked = true;
        break;
      }
    }
    if (clicked) {
      continue;
    }
    // The vault is up. A dialog can still open a moment later; look again.
    await page.waitForTimeout(2_000);
    if ((await page.getByRole('dialog').count()) === 0 && (await vault.isVisible())) {
      return;
    }
  }
  throw new Error('the vault never showed without a dialog over it (an onboarding screen these tests do not know?)');
}

export async function logOut(page: Page): Promise<void> {
  await step('log out', async () => {
    // The account menu is the button named after the account ("e2e").
    await page.getByRole('main').getByRole('button', { name: 'e2e', exact: true }).click();
    await page.getByRole('menuitem', { name: 'Log out' }).click();
    await expect(page.getByRole('heading', { name: 'Log in' })).toBeVisible();
  });
}

// openItem finds one item by its (unique) name and opens its view dialog.
export async function openItem(page: Page, name: string): Promise<Locator> {
  return step(`open the item "${name}"`, async () => {
    await page.getByRole('textbox', { name: 'Search' }).fill(name);
    const rows = page.getByRole('row').filter({ has: page.getByRole('button', { name, exact: true }) });
    await expect(rows).toHaveCount(1);
    await rows.getByRole('button', { name, exact: true }).click();
    const view = page.getByRole('dialog', { name: 'View login' });
    await expect(view.getByRole('heading', { name, exact: true })).toBeVisible();
    return view;
  });
}
