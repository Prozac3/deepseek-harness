// Zero-dependency cookie authentication service for the dsh Web reverse proxy.
// Nginx performs the proxying; this service owns only login and auth probes.
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const DIRECTORY = dirname(fileURLToPath(import.meta.url))
const COOKIE = 'dsh_auth'
const MAX_AGE_SECONDS = 60 * 60 * 12
const MAX_FORM_BYTES = 64 * 1024
const DEFAULT_PORT = 3082
const DUMMY_ORIGIN = 'http://dsh-proxy.invalid'
const CONFIG_NAMES = ['AUTH_PORT', 'AUTH_USER', 'AUTH_PASS', 'SESSION_SECRET']

function readDotEnv() {
  try {
    const values = {}
    for (const line of readFileSync(resolve(DIRECTORY, '.env'), 'utf8').split('\n')) {
      const match = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/u)
      if (match) values[match[1]] = match[2].replace(/^['"]|['"]$/gu, '')
    }
    return values
  } catch (error) {
    if (error?.code === 'ENOENT') return {}
    throw error
  }
}

function readConfig() {
  const values = { ...readDotEnv() }
  for (const name of CONFIG_NAMES) {
    if (process.env[name] !== undefined) values[name] = process.env[name]
  }
  return {
    port: Number(values.AUTH_PORT ?? DEFAULT_PORT),
    user: values.AUTH_USER,
    pass: values.AUTH_PASS,
    secret: values.SESSION_SECRET,
  }
}

function normalizeConfig(config) {
  const resolved = {
    port: config.port ?? DEFAULT_PORT,
    user: config.user,
    pass: config.pass,
    secret: config.secret,
  }
  if (!Number.isInteger(resolved.port) || resolved.port < 0 || resolved.port > 65535) {
    throw new Error('AUTH_PORT must be an integer from 0 through 65535')
  }
  if (!resolved.user || !resolved.pass || !resolved.secret) {
    throw new Error('AUTH_USER / AUTH_PASS / SESSION_SECRET must be configured')
  }
  return resolved
}

function escapeHtml(value) {
  return value.replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

function safeNext(value) {
  if (typeof value !== 'string' || value === '' || value.length > 2048
    || !value.startsWith('/') || value.startsWith('//') || value.includes('\\')) return '/'
  try {
    const parsed = new URL(value, DUMMY_ORIGIN)
    if (parsed.origin !== DUMMY_ORIGIN) return '/'
    const result = `${parsed.pathname}${parsed.search}${parsed.hash}`
    return result.length <= 500 ? result : '/'
  } catch {
    return '/'
  }
}

function sign(secret, payload) {
  return createHmac('sha256', secret).update(payload).digest('base64url')
}

function safeEqual(secret, actual, expected) {
  const actualDigest = createHmac('sha256', secret).update(actual).digest()
  const expectedDigest = createHmac('sha256', secret).update(expected).digest()
  return timingSafeEqual(actualDigest, expectedDigest)
}

function readSession(req, config) {
  const cookieHeader = typeof req.headers.cookie === 'string' ? req.headers.cookie : ''
  for (const part of cookieHeader.split(';')) {
    const equals = part.indexOf('=')
    if (equals < 0 || part.slice(0, equals).trim() !== COOKIE) continue
    const value = part.slice(equals + 1).trim()
    const dot = value.lastIndexOf('.')
    if (dot < 0) return false
    const payload = value.slice(0, dot)
    const mac = value.slice(dot + 1)
    const separator = payload.lastIndexOf(':')
    const user = separator < 0 ? '' : payload.slice(0, separator)
    const expires = separator < 0 ? NaN : Number(payload.slice(separator + 1))
    if (user !== config.user || !Number.isSafeInteger(expires)
      || expires <= Math.floor(Date.now() / 1000)) return false
    if (safeEqual(config.secret, mac, sign(config.secret, payload))) return true
  }
  return false
}

function loginPage(next, error = '') {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DeepSeek Harness</title>
<style>
  :root { --bg: #151517; --card: #1b1b1c; --border: rgba(255,255,255,.06); --text: #f5f6f7; --muted: #979da6; --primary: #5686fe; --error: #f56c6c; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { min-height: 100vh; display: flex; align-items: center; justify-content: center; background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
  .card { width: 340px; padding: 32px; background: var(--card); border: 1px solid var(--border); border-radius: 12px; }
  .mark { display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }
  .mark svg { flex: none; }
  .title { font-size: 18px; font-weight: 700; }
  .subtitle { font-size: 13px; color: var(--muted); margin-bottom: 24px; }
  label { display: block; font-size: 13px; color: var(--muted); margin: 14px 0 6px; }
  input { width: 100%; padding: 9px 12px; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; color: var(--text); font-size: 14px; outline: none; }
  input:focus { border-color: var(--primary); }
  .error { color: var(--error); font-size: 13px; margin-top: 12px; min-height: 18px; }
  button { width: 100%; margin-top: 18px; padding: 10px; background: var(--primary); border: none; border-radius: 8px; color: #fff; font-size: 14px; font-weight: 600; cursor: pointer; }
</style>
</head>
<body>
  <form class="card" method="post" action="/login">
    <div class="mark">
      <svg width="28" height="28" viewBox="0 0 32 32" fill="none" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#5686fe"/><path d="M9 21V11l7 6 7-6v10" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
      <div class="title">DeepSeek Harness</div>
    </div>
    <div class="subtitle">登录以访问 Agent Web UI</div>
    <input type="hidden" name="next" value="${escapeHtml(next)}">
    <label for="user">用户名</label>
    <input id="user" name="user" autocomplete="username" required autofocus>
    <label for="pass">密码</label>
    <input id="pass" name="pass" type="password" autocomplete="current-password" required>
    <div class="error">${escapeHtml(error)}</div>
    <button type="submit">登录</button>
  </form>
</body>
</html>`
}

function requestNext(req) {
  try {
    return safeNext(new URL(req.url ?? '/', DUMMY_ORIGIN).searchParams.get('next'))
  } catch {
    return '/'
  }
}

function responseHeaders() {
  return {
    'Cache-Control': 'no-store',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
  }
}

function createHandler(config) {
  return (req, res) => {
    let url
    try {
      url = new URL(req.url ?? '/', DUMMY_ORIGIN)
    } catch {
      res.writeHead(400, { 'Content-Length': '0' })
      res.end()
      return
    }

    if (url.pathname === '/_auth') {
      res.writeHead(readSession(req, config) ? 200 : 401, {
        ...responseHeaders(),
        'Content-Length': '0',
      })
      res.end()
      return
    }

    if (url.pathname === '/login' && req.method === 'GET') {
      res.writeHead(200, { ...responseHeaders(), 'Content-Type': 'text/html; charset=utf-8' })
      res.end(loginPage(requestNext(req)))
      return
    }

    if (url.pathname === '/login' && req.method === 'POST') {
      let body = ''
      let bytes = 0
      let oversized = false
      req.on('data', chunk => {
        bytes += Buffer.byteLength(chunk)
        if (bytes <= MAX_FORM_BYTES) body += chunk
        else oversized = true
      })
      req.on('end', () => {
        if (oversized) {
          res.writeHead(413, { ...responseHeaders(), 'Content-Length': '0' })
          res.end()
          return
        }
        const params = new URLSearchParams(body)
        const user = params.get('user') ?? ''
        const pass = params.get('pass') ?? ''
        const next = safeNext(params.get('next'))
        if (safeEqual(config.secret, user, config.user) && safeEqual(config.secret, pass, config.pass)) {
          const expires = Math.floor(Date.now() / 1000) + MAX_AGE_SECONDS
          const payload = `${config.user}:${expires}`
          const secure = req.headers['x-forwarded-proto'] === 'https' ? '; Secure' : ''
          const cookie = `${COOKIE}=${payload}.${sign(config.secret, payload)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${MAX_AGE_SECONDS}${secure}`
          res.writeHead(302, {
            ...responseHeaders(),
            Location: next,
            'Set-Cookie': cookie,
          })
          res.end()
          return
        }
        res.writeHead(200, { ...responseHeaders(), 'Content-Type': 'text/html; charset=utf-8' })
        res.end(loginPage(next, '用户名或密码错误'))
      })
      return
    }

    res.writeHead(404, { ...responseHeaders(), 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('Not found')
  }
}

/** Create the unlistened loopback authentication service. */
export function createAuthServer(config = readConfig()) {
  const resolved = normalizeConfig(config)
  return createServer(createHandler(resolved))
}

/** Start the authentication service on loopback and return its server handle. */
export function startAuthServer(config = readConfig()) {
  const resolved = normalizeConfig(config)
  const server = createServer(createHandler(resolved))
  server.listen(resolved.port, '127.0.0.1', () => {
    console.log(`auth server listening on http://127.0.0.1:${String(resolved.port)}`)
  })
  return server
}

const entry = process.argv[1]
if (entry !== undefined && import.meta.url === pathToFileURL(resolve(entry)).href) {
  try {
    startAuthServer()
  } catch (error) {
    console.error(`auth-server: ${error instanceof Error ? error.message : String(error)}`)
    process.exitCode = 1
  }
}
