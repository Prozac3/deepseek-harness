# dsh-proxy

English | [中文](README.zh.md)

## Summary

This directory provides a single-user, cookie-authenticated Nginx front end for dsh Web. Nginx protects the UI, API, streaming responses, and WebSocket upgrade with one login-service cookie, then forwards authenticated requests to dsh over loopback.

## Start

Build the Web artifacts and create a local credential file:

```sh
pnpm install
pnpm run build
cp dsh-proxy/.env.example dsh-proxy/.env
openssl rand -hex 32
chmod 600 dsh-proxy/.env
```

Put the generated value in `SESSION_SECRET`, replace `AUTH_USER` and `AUTH_PASS`, then start the three local processes:

```sh
chmod +x dsh-proxy/start.sh
./dsh-proxy/start.sh
```

Open `http://127.0.0.1:3080` and enter the configured login credentials. The helper starts dsh on `127.0.0.1:3081`, the login service on `127.0.0.1:3082`, and Nginx on `0.0.0.0:3080`. Press `Ctrl-C` to stop the process groups started by the helper.

## Deploy to `~/app`

Run the deployment helper after configuring `dsh-proxy/.env`:

```sh
./dsh-proxy/deploy-app.sh
cd ~/app
./start.sh
```

The helper builds the repository with pnpm, collects the CLI production dependency closure, and places it with the proxy files in `~/app`. pnpm is needed only in the source checkout during deployment. The deployed `start.sh` runs `./dsh web` directly through the built CLI and requires only Node.js and Nginx at runtime.

An existing target is updated only when it contains the deployment marker. Its `.env` and isolated `.dsh-home` are preserved; other managed files are replaced with the new production artifacts. Before updating the target, the helper starts the staged `dsh web` on a random loopback port and waits for readiness. Pass an absolute directory as the first argument to deploy somewhere other than `~/app`; `--skip-build` reuses already-built source artifacts.

## Configuration

The login service reads `dsh-proxy/.env`; process environment variables override values from that file. `AUTH_PORT`, `AUTH_USER`, `AUTH_PASS`, and `SESSION_SECRET` are required, and the secret signs the HttpOnly session cookie. The checked-in `.env.example` contains placeholders only; `.env` is ignored.

The helper sets `DSH_HOME` to `.dsh-home` beside `start.sh` by default, or to `DSH_PROXY_HOME` when that variable is set. dsh initializes that isolated profile with only the built-in `base` and `web-app` bundles; it does not load plugins from the user's normal `~/.dsh` profile. The dsh process runs with `--host 127.0.0.1 --trust-proxy-auth`. Connection accepts the proxy assertion only from a loopback socket peer, and Nginx overwrites that assertion after its cookie check succeeds. The authenticated page can manage Host settings, including model providers, plugin configuration, and presets. The dsh launch-token URL is not printed or opened in this mode.

## Public deployment

The included listener is an HTTP example for local use. For access outside localhost, terminate HTTPS at the public Nginx listener, replace `dsh.example.com` in the dsh command and service example, and keep ports `3081` and `3082` bound to loopback and unreachable from the network. Do not expose the auth service or the dsh listener directly.

The proxy is single-user: the configured login principal gates the whole dsh process, and the proxy assertion carries no user identity. The login service rejects external redirect targets, escapes reflected form values, signs cookies with HMAC-SHA-256, and marks cookies `Secure` when Nginx reports an HTTPS request.

## systemd examples

Copy [`dsh-web.service.example`](dsh-web.service.example) and [`dsh-auth.service.example`](dsh-auth.service.example) to the host's systemd unit directory, replace the path and `dsh.example.com` placeholders, then enable both units. The examples keep dsh and the auth service on loopback and load secrets only through the local environment file.

## Verification

Run the dependency-free auth-service checks and validate the Nginx template when Nginx is installed:

```sh
node --test dsh-proxy/auth-server.test.mjs
node --check dsh-proxy/auth-server.mjs
nginx -t -p "$PWD/dsh-proxy/" -c nginx.conf
```

The last command requires Nginx and validates `dsh-proxy/nginx.conf`; it does not start the proxy.
