import assert from 'node:assert/strict'
import { once } from 'node:events'
import test from 'node:test'
import { createAuthServer } from './auth-server.mjs'

let server
let base

test.before(async () => {
  server = createAuthServer({ user: 'admin', pass: 'correct', secret: 'test-secret', port: 0 })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  base = `http://127.0.0.1:${String(server.address().port)}`
})

test.after(async () => {
  server.close()
  await once(server, 'close')
})

test('login and auth probe use a signed HttpOnly cookie', async () => {
  const login = await fetch(`${base}/login?next=${encodeURIComponent('/chat')}`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-forwarded-proto': 'https' },
    body: new URLSearchParams({ user: 'admin', pass: 'correct', next: '/chat' }),
    redirect: 'manual',
  })
  assert.equal(login.status, 302)
  assert.equal(login.headers.get('location'), '/chat')
  const setCookie = login.headers.get('set-cookie')
  assert.match(setCookie, /HttpOnly/)
  assert.match(setCookie, /SameSite=Lax/)
  assert.match(setCookie, /Secure/)
  assert.equal((await fetch(`${base}/_auth`)).status, 401)
  assert.equal((await fetch(`${base}/_auth`, {
    headers: { cookie: setCookie.split(';', 1)[0] },
  })).status, 200)
})

test('login form escapes the next path and preserves it after a bad password', async () => {
  const malicious = '/chat?x=""><script>alert(1)</script>'
  const page = await fetch(`${base}/login?next=${encodeURIComponent(malicious)}`)
  const html = await page.text()
  assert.doesNotMatch(html, /<script>/)
  assert.match(html, /name="next" value="\/[^\"]+"/)

  const failed = await fetch(`${base}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ user: 'admin', pass: 'wrong', next: '/chat' }),
  })
  assert.match(await failed.text(), /value="\/chat"/)
})

test('safe redirects reject external authorities and backslashes', async () => {
  for (const next of ['https://example.com', '//example.com', '/\\example.com']) {
    const response = await fetch(`${base}/login?next=${encodeURIComponent(next)}`)
    const html = await response.text()
    assert.match(html, /name="next" value="\/"/)
  }
})
