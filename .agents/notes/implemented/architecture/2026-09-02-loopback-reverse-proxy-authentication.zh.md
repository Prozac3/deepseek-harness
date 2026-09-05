# Agent Note: dsh Web 的 loopback reverse-proxy 认证

Status: implemented

[English](2026-09-02-loopback-reverse-proxy-authentication.md) | 中文

## 问题

dsh Web 原生的启动 token URL 适合直接 loopback 使用，但带 Cookie 认证的 Nginx 部署需要一套 Connection 能验证的认证流程。

## 决定

Connection 提供默认关闭的可选 `trustProxyAuth` 设置。请求只有在 socket peer 是 loopback 时，才能使用固定的 `X-DSH-Proxy-Auth: 1` 声明。Node HTTP 适配器会为 index、API 与 WebSocket 认证判断保留 peer 地址。此模式提供的 index 会为 Client 启用 Host 设置，因此浏览器 hostname 检查不会在已认证代理后面禁用模型提供方、插件配置与预设。Web 表层通过 `--trust-proxy-auth` 暴露该设置；关闭时原生 token 认证保持不变。

`dsh-proxy` 的 Nginx 配置会在 `auth_request` 成功后覆盖该声明，而 dsh 仍然绑定在 `127.0.0.1`。启动辅助脚本启用该可选模式，因此用户只需在代理登录页认证；代理模式不会打印或打开原生 token URL。

启动辅助脚本默认使用独立的 `DSH_HOME`，因此只加载内置 Web profile。可以通过 `DSH_PROXY_HOME` 选择另一个独立的 profile 目录，但不会导入用户普通 dsh home 中的插件。

部署辅助脚本会把 CLI 与其生产依赖构建到一个受管理的应用目录中。部署后的启动器以 `dsh web` 执行构建好的 CLI，因此 pnpm 只是源码构建工具，不是运行期依赖。更新时只保留本地凭据文件与独立 dsh home。

## 考虑过的替代方案

**通过原生 token URL 重定向用户。** 不采用，因为这会把第二个 bearer 凭据暴露给操作者和浏览器历史，而且代理仍然拥有另一套独立会话，不能形成一个登录流程。

**任何携带该 header 的请求都接受。** 不采用，因为外部调用方可以伪造 header。接受路径同时要求 loopback socket peer 与显式设置，且 Nginx 只会在上游认证成功后覆盖该 header。

**所有场景都用代理认证替换原生浏览器认证。** 不采用，因为直接启动 dsh Web 仍需要现有 token 与绑定 authority 的 cookie 行为。代理认证只对部署显式启用。

## 后果

随附的 `dsh-proxy` 流程中，代理登录服务是唯一面向用户的凭据输入。该声明不携带用户身份，因此该部署仍是单一 principal；向 localhost 之外暴露时必须在公共监听器上配置 TLS。代理模式会启用持久 Host 设置，但不会将远程浏览器视为 loopback，因此本地路径控件仍保留设备限制。原生 token exchange 仍是默认行为，关闭代理认证时仍然要求它；直接启动约定记录在[浏览器令牌认证说明](2026-08-24-browser-token-authentication.zh.md)中。

## 验证

聚焦测试覆盖 BrowserAuth、Node HTTP 路由、Remote WebSocket upgrade、Web flag 透传以及无依赖登录服务。语法检查覆盖认证服务、部署辅助脚本、启动器和启动辅助脚本；隔离的生产部署必须能够加载 `dsh web`。安装 Nginx 时会校验 Nginx 配置。
