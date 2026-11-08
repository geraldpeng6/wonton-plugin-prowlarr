# 云吞插件：Prowlarr

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

云吞（Wonton）的 Prowlarr 插件：把影视索引器集中到一处管理，测连通性、自动同步给 Radarr、Sonarr 这类应用，也能直接搜索并把种子抓进下载队列。

这个插件使用上游安装文档指定的 [LinuxServer.io 镜像](https://docs.linuxserver.io/images/docker-prowlarr/)（Docker Hub 名 `linuxserver/prowlarr`，amd64 和 arm64），按清单列表摘要固定。网页经云吞网关访问：第一次打开时，应用会要求设置管理员账号和密码（Forms 认证，*arr 的"启用认证"页，用户名密码自己定），之后网页在云吞网关和应用的两层登录后面。

## qBittorrent 下载客户端

装了 qBittorrent 插件并在云吞里把 `torrent_client` 能力指向它时，插件会把 qBittorrent（Web API v2）登记成 Prowlarr 的下载客户端，地址读自 `WONTON_TORRENT_CLIENT_URL`，免凭据；已手动配过 qBittorrent 的不会被改动。能力还没接线时跳过这一步，其他功能照常。

## 通知邮件

装好插件时，插件在应用的 设置 → Connect 里建一个 "Wonton" 的 Email 通知连接：服务器是云吞的内部邮箱（不认证、不加密），收件人是主人的内部邮箱。健康问题、健康恢复、应用更新三类通知默认打开，出现在收件人的 Wonton 私聊里；每次抓取发一封的信默认不发（量太大），要收在连接设置里打开"抓取"。信进不了外面的邮箱：把收件地址改成外部邮箱，云吞会拒收，应用报发送失败。已手动配过 Email 连接的不会被改动。

## 图标来源与许可

`icon.svg` 使用 Prowlarr 官方标志；来源、处理方式、许可证全文和商标说明见 [NOTICE](NOTICE)。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞，打印它的地址。浏览器打开，用 `scripts/dev.sh token` 输出的用户令牌登录。`install` 先列出插件要的权限，确认后装上，打印 Prowlarr 网页的地址。第一次打开 Prowlarr 会出现"启用认证"页：设置用户名和密码（自己定），提交后就用这套账号登录应用。

搜索和抓取需要能访问外网；索引器和设置保存在插件数据目录，重装不丢（认证设置也在里面）。

Chrome、Firefox 和 curl 把 `*.localhost` 直接解析到本机，不用改 hosts。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：Compose 加上 `x-wonton` 清单 |
| `provision.sh` | 一次性服务：把 torrent_client 能力登记成下载客户端 |
| `mail.sh` | 一次性服务：把应用的通知邮件接到云吞的内部邮箱 |
| `icon.svg`、`NOTICE` | 官方图标和它的许可声明 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | 冒烟对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件包许可证、上游许可证和商标声明 |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |
