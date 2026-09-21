import { openChart } from './photo-fixture.js'
import { test, expect } from '@playwright/test'

test('compiled films clear unsupported settings and remain renderable without authoring assets', async ({ page }) => {
  const errors = [], definitions = []
  page.on('pageerror', error => errors.push(error.message))
  page.on('request', request => {
    if (request.url().includes('/profile/stocks/gold200.json')) definitions.push(request.url())
  })
  await page.route('**/profile/catalogue.json*', async route => {
    const response = await route.fetch(), catalogue = await response.json()
    catalogue.gold200 = { ...catalogue.gold200, settings: 'fixed', available: [] }
    await route.fulfill({ response, json: catalogue })
  })
  await page.goto('/')
  await openChart(page, 320, 192)
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(/\d+ × \d+/)
  await page.getByRole('searchbox').fill('Portra 400')
  await page.getByTitle('Portra 400', { exact: true }).click()
  await page.getByRole('combobox', { name: 'Format', exact: true }).click()
  await page.getByRole('option', { name: '35mm still', exact: true }).click()
  await page.getByRole('searchbox').fill('Gold 200')
  await page.getByTitle('Gold 200', { exact: true }).click()
  await expect(page.getByText('This film uses a fixed profile.', { exact: false })).toBeVisible()
  await expect(page.getByRole('combobox', { name: 'Format', exact: true })).toHaveCount(0)
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(/\d+ × \d+/)
  await page.getByRole('tab', { name: 'Print', exact: true }).click()
  await expect(page.getByRole('combobox', { name: 'Print Frame', exact: true })).toHaveCount(0)
  await page.getByRole('button', { name: 'More options', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Auto Adjust', exact: true })).toBeDisabled()
  expect(definitions).toEqual([])
  expect(errors).toEqual([])
})
