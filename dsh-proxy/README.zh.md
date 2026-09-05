# dsh-proxy

[English](README.md) | 中文

## 摘要

本目录提供单用户、Cookie 认证的 Nginx 前端，用于 dsh Web。Nginx 用一套登录服务 Cookie 保护界面、API、流式响应和 WebSocket upgrade，然后通过 loopback 将已认证请求转发给 dsh。

## 启动

先构建 Web 产物并创建本地凭据文件：

```sh
pnpm install
pnpm run build
cp dsh-proxy/.env.example dsh-proxy/.env
openssl rand -hex 32
chmod 600 dsh-proxy/.env
```

将生成的值填入 `SESSION_SECRET`，替换 `AUTH_USER` 和 `AUTH_PASS`，然后启动三个本地进程：

```sh
chmod +x dsh-proxy/start.sh
./dsh-proxy/start.sh
```

打开 `http://127.0.0.1:3080` 并输入配置的登录凭据。辅助脚本会让 dsh 监听 `127.0.0.1:3081`，让登录服务监听 `127.0.0.1:3082`，并让 Nginx 监听 `0.0.0.0:3080`。按 `Ctrl-C` 会停止辅助脚本启动的进程组。

## 部署到 `~/app`

配置好 `dsh-proxy/.env` 后运行部署辅助脚本：

```sh
./dsh-proxy/deploy-app.sh
cd ~/app
./start.sh
```

辅助脚本会用 pnpm 构建仓库、收集 CLI 的生产依赖闭包，并将其与代理文件一起放入 `~/app`。pnpm 只在部署时的源码 checkout 中需要。部署后的 `start.sh` 会通过构建好的 CLI 直接运行 `./dsh web`，运行期只需要 Node.js 与 Nginx。

只有包含部署标记的现有目标目录才会被更新。目录中的 `.env` 与隔离 `.dsh-home` 会保留，其他受管理文件会替换为新的生产产物。更新目标目录前，辅助脚本会在随机 loopback 端口启动暂存的 `dsh web` 并等待就绪。若不部署到 `~/app`，可将绝对目录作为第一个参数传入；`--skip-build` 会复用已经构建的源码产物。

## 配置

登录服务读取 `dsh-proxy/.env`；进程环境变量会覆盖该文件中的值。`AUTH_PORT`、`AUTH_USER`、`AUTH_PASS` 和 `SESSION_SECRET` 都是必需项，secret 用于签名 HttpOnly 会话 Cookie。已提交的 `.env.example` 只包含占位值；`.env` 会被忽略。

dsh 辅助脚本默认将 `DSH_HOME` 设为 `start.sh` 旁边的 `.dsh-home`；也可以通过 `DSH_PROXY_HOME` 指定目录。dsh 会在该隔离 profile 中只初始化内置的 `base` 与 `web-app` 组合包，不会加载用户普通 `~/.dsh` profile 中的插件。dsh 进程使用 `--host 127.0.0.1 --trust-proxy-auth` 启动。Connection 只接受来自 loopback socket peer 的代理声明，Nginx 仅在 Cookie 检查成功后覆盖该声明。认证后的页面可以管理 Host 设置，包括模型提供方、插件配置与预设。该模式不会打印或打开 dsh 启动 token URL。

## 公网部署

随附监听器是供本地使用的 HTTP 示例。若要从 localhost 之外访问，请在公共 Nginx 监听器上终止 HTTPS，替换 dsh 命令和 service 示例中的 `dsh.example.com`，并确保 `3081` 与 `3082` 仍绑定 loopback、无法从网络访问。不要直接暴露认证服务或 dsh 监听器。

代理是单用户的：配置的登录 principal 控制整个 dsh 进程，代理声明不携带用户身份。登录服务会拒绝外部 redirect 目标、转义回显的表单值、使用 HMAC-SHA-256 签名 Cookie，并在 Nginx 报告 HTTPS 请求时为 Cookie 设置 `Secure`。

## systemd 示例

将 [`dsh-web.service.example`](dsh-web.service.example) 和 [`dsh-auth.service.example`](dsh-auth.service.example) 复制到主机的 systemd unit 目录，替换路径和 `dsh.example.com` 占位符，然后启用两个 unit。示例会让 dsh 与认证服务保持 loopback 监听，并且只通过本地环境文件加载 secret。

## 验证

运行无依赖的认证服务检查，并在安装了 Nginx 时校验 Nginx 模板：

```sh
node --test dsh-proxy/auth-server.test.mjs
node --check dsh-proxy/auth-server.mjs
nginx -t -p "$PWD/dsh-proxy/" -c nginx.conf
```

最后一条命令需要 Nginx，并校验 `dsh-proxy/nginx.conf`；它不会启动代理。
