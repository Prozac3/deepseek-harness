# Agent Note: Loopback reverse-proxy authentication for dsh Web

Status: implemented

English | [中文](2026-09-02-loopback-reverse-proxy-authentication.zh.md)

## Problem

dsh Web's native launch-token URL is suitable for direct loopback use, but a cookie-authenticated Nginx deployment needs one authentication flow that Connection can verify.

## Decision

Connection exposes an opt-in `trustProxyAuth` setting, disabled by default. A request may use the fixed `X-DSH-Proxy-Auth: 1` assertion only when its socket peer is loopback. Node HTTP adapters preserve the peer address for index, API, and WebSocket authentication decisions. The served index enables Host settings for the Client in this mode, so browser-hostname checks do not disable model providers, plugin configuration, and presets behind the authenticated proxy. The Web profile exposes the setting as `--trust-proxy-auth` and keeps native token authentication unchanged when the setting is off.

The `dsh-proxy` Nginx configuration overwrites the assertion after its `auth_request` succeeds, while dsh remains bound to `127.0.0.1`. Its startup helper enables the opt-in mode, so users authenticate only at the proxy login page; proxy mode does not print or open the native token URL.

The startup helper uses a dedicated `DSH_HOME` by default and therefore loads only the built-in Web profile. `DSH_PROXY_HOME` can select another dedicated profile directory without importing plugins from the user's normal dsh home.

The deployment helper builds the CLI and its production dependencies into one managed app directory. The deployed launcher executes the built CLI as `dsh web`, so pnpm remains a source-build tool rather than a runtime dependency. Updates preserve only the local credential file and dedicated dsh home.

## Alternatives considered

**Redirect users through the native token URL.** Rejected because it exposes a second bearer credential to the operator and browser history, and leaves the proxy owning a separate session instead of composing one login flow.

**Accept the assertion from any request carrying the header.** Rejected because an external caller could forge the header. The accepted path requires both the loopback socket peer and the opt-in setting, while Nginx overwrites the header on authenticated upstream requests.

**Replace native browser authentication with proxy authentication everywhere.** Rejected because direct dsh Web launches still need their existing token and authority-bound cookie behavior. Proxy authentication is a deployment opt-in.

## Consequences

The proxy login service is the only user-facing credential prompt in the shipped `dsh-proxy` flow. The assertion carries no user identity, so this deployment remains single-principal; deployments exposing it beyond localhost must add TLS at the public listener. Proxy mode enables persistent Host settings without treating the remote browser as loopback, so local-path controls retain their device restriction. Native token exchange remains the default and remains required when proxy authentication is disabled; its direct-launch contract is recorded in the [browser token authentication note](2026-08-24-browser-token-authentication.md).

## Verification

Focused tests cover BrowserAuth, node HTTP routes, Remote WebSocket upgrades, Web flag propagation, and the dependency-free login service. Syntax checks cover the auth service, deployment helper, launcher, and startup helper; an isolated production deployment must load `dsh web`. The Nginx configuration is validated when Nginx is installed.
