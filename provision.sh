#!/bin/sh
# 把 torrent_client 能力（qBittorrent Web API v2）登记成 Prowlarr 的下载客户端。
# 核心按能力接线后注入 WONTON_TORRENT_CLIENT_URL（如 http://torrent-client.wonton.internal:8080），
# 免凭据：流量经核心别名进 qBittorrent，落在它的核心来源白名单里。
# 每次创建容器都会重跑，必须幂等：能力没接线时说明并跳过；已有 qBittorrent 客户端时不改用户配置。
set -eu

api="http://prowlarr:9696/api/v1"

url="${WONTON_TORRENT_CLIENT_URL:-}"
if [ -z "$url" ]; then
  echo "没有 WONTON_TORRENT_CLIENT_URL：torrent_client 能力还没接线（声明字段等核心定稿），跳过下载客户端登记"
  exit 0
fi

# 拆地址：协议、主机、端口、路径前缀。
case "$url" in
  http://*) ssl=false; rest=${url#http://} ;;
  https://*) ssl=true; rest=${url#https://} ;;
  *) echo "WONTON_TORRENT_CLIENT_URL 要以 http:// 或 https:// 开头：$url"; exit 1 ;;
esac
base=""
case "$rest" in
  */*) base="/${rest#*/}"; rest="${rest%%/*}" ;;
esac
case "$rest" in
  *:*) host=${rest%%:*}; port=${rest#*:} ;;
  *)   host=$rest; if [ "$ssl" = true ]; then port=443; else port=80; fi ;;
esac
[ -n "$host" ] || { echo "WONTON_TORRENT_CLIENT_URL 没有主机名：$url"; exit 1; }
case "$port" in
  ''|*[!0-9]*) echo "WONTON_TORRENT_CLIENT_URL 的端口不是数字：$url"; exit 1 ;;
esac
case "$base" in
  /|'') base="" ;;
  */) base=${base%/} ;;
esac

# 拿应用自己的 API key（provision 在 prowlarr 健康后才跑，config.xml 通常已就绪，仍兜底等一分钟）。
key=""
i=0
while [ "$i" -lt 30 ]; do
  key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml 2>/dev/null || true)
  [ -n "$key" ] && break
  i=$((i + 1))
  sleep 2
done
[ -n "$key" ] || { echo "config.xml 里读不到 ApiKey"; exit 1; }

get() {
  curl --noproxy '*' -fsS -H "X-Api-Key: $key" "$api/$1"
}

# API 就绪重试：/ping 过了但路由偶尔还会慢半拍。
list=""
i=0
while :; do
  if list=$(get downloadclient); then break; fi
  i=$((i + 1))
  [ "$i" -lt 15 ] || { echo "Prowlarr 的 API 一直没就绪"; exit 1; }
  sleep 2
done

existing=$(printf '%s' "$list" | jq '[.[] | select(.implementation == "QBittorrent")] | length')
if [ "$existing" -ge 1 ]; then
  echo "已有 $existing 个 qBittorrent 下载客户端，不改用户配置"
  exit 0
fi

tpl=$(get downloadclient/schema | jq -c '[.[] | select(.implementation == "QBittorrent")][0]')
if [ -z "$tpl" ] || [ "$tpl" = null ]; then echo "下载客户端 schema 里没有 QBittorrent 实现"; exit 1; fi

# 字段名和默认值都取自 schema，不自己拼；只填主机、端口、协议和路径前缀。
payload=$(printf '%s' "$tpl" | jq -c --arg host "$host" --argjson port "$port" --argjson ssl "$ssl" --arg base "$base" '
  {
    name: "qBittorrent",
    enable: true,
    protocol: "torrent",
    implementation: .implementation,
    configContract: .configContract,
    priority: (.priority // 1),
    tags: [],
    fields: [
      .fields[]
      | if .name == "host" then .value = $host
        elif .name == "port" then .value = $port
        elif .name == "useSsl" then .value = $ssl
        elif .name == "urlBase" then .value = (if $base == "" then null else $base end)
        else . end
    ]
  }')

# enable=true 时应用会先测一次和 qBittorrent 的连通，通过才创建：登记成功即连通证明。
# 连不上时带重试（对方插件可能正在启动），重试满了带着应用的报错退出。
code=""
i=0
while :; do
  code=$(curl --noproxy '*' -sS -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    -d "$payload" -o /tmp/dc-created.json -w '%{http_code}' "$api/downloadclient" || true)
  case "$code" in
    200 | 201) break ;;
  esac
  i=$((i + 1))
  [ "$i" -lt 3 ] || {
    echo "登记下载客户端失败（HTTP $code），应用返回："
    cat /tmp/dc-created.json 2>/dev/null || true
    exit 1
  }
  sleep 5
done

id=$(jq -r '.id' /tmp/dc-created.json)
case "$id" in
  ''|null) echo "创建后读不到 id：$(cat /tmp/dc-created.json)"; exit 1 ;;
esac
echo "已登记 qBittorrent 下载客户端并连通（id=$id）：$host:$port useSsl=$ssl urlBase=${base:-无}"
