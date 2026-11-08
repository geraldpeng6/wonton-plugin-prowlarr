#!/bin/sh
# 把 Email 通知接到核心的内部邮箱：装好就有，应用发的信转进收件人的 Wonton 私聊。
# 每次创建容器都会重跑，必须幂等：已有 Email 通知时不改用户配置。
set -eu

api="http://prowlarr:9696/api/v1"

# notify 给 SMTP 三件套，owner.identity 给收件地址；缺了安装在这里报清楚，不等发信才失败。
host="${WONTON_SMTP_HOST:?}"
port="${WONTON_SMTP_PORT:?}"
case "$port" in
  ''|*[!0-9]*) echo "WONTON_SMTP_PORT 不是数字：$port"; exit 1 ;;
esac
from="${WONTON_MAIL_FROM:?}"
owner="${WONTON_OWNER_EMAIL:?}"

# 拿应用自己的 API key（mail 在 prowlarr 健康后才跑，config.xml 通常已就绪，仍兜底等一分钟）。
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
  if list=$(get notification); then break; fi
  i=$((i + 1))
  [ "$i" -lt 15 ] || { echo "Prowlarr 的 API 一直没就绪"; exit 1; }
  sleep 2
done

existing=$(printf '%s' "$list" | jq '[.[] | select(.implementation == "Email")] | length')
if [ "$existing" -ge 1 ]; then
  echo "已有 $existing 个 Email 通知连接，不改用户配置"
  exit 0
fi

tpl=$(get notification/schema | jq -c '[.[] | select(.implementation == "Email")][0]')
if [ -z "$tpl" ] || [ "$tpl" = null ]; then echo "通知 schema 里没有 Email 实现"; exit 1; fi

# 字段名和默认值都取自 schema，不自己拼。加密显式关成 Never（枚举 2）：核心的 SMTP 不加密，
# 默认的 Preferred 会在明文 25 端口上尝试升级；用户名密码留空，应用就不发 AUTH。
# 收件人是主人的内部邮箱；健康问题、健康恢复、应用更新默认开，抓取信默认不开（每抓一次发一封，量太大），
# 要收在连接设置里打开"抓取"。
payload=$(printf '%s' "$tpl" | jq -c --arg host "$host" --argjson port "$port" --arg from "$from" --arg to "$owner" '
  {
    name: "Wonton",
    implementation: .implementation,
    configContract: .configContract,
    tags: [],
    onGrab: false,
    onHealthIssue: true,
    onHealthRestored: true,
    onApplicationUpdate: true,
    fields: [
      .fields[]
      | if .name == "server" then .value = $host
        elif .name == "port" then .value = $port
        elif .name == "useEncryption" then .value = 2
        elif .name == "from" then .value = $from
        elif .name == "to" then .value = [$to]
        else . end
    ]
  }')

# 健康类触发器开着，应用会先发一封测试信、通过才创建：登记成功即发信通路证明。
# 发不出去时带重试，重试满了带着应用的报错退出。
code=""
i=0
while :; do
  code=$(curl --noproxy '*' -sS -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    -d "$payload" -o /tmp/mail-created.json -w '%{http_code}' "$api/notification" || true)
  case "$code" in
    200 | 201) break ;;
  esac
  i=$((i + 1))
  [ "$i" -lt 3 ] || {
    echo "登记 Email 通知失败（HTTP $code），应用返回："
    cat /tmp/mail-created.json 2>/dev/null || true
    exit 1
  }
  sleep 5
done

id=$(jq -r '.id' /tmp/mail-created.json)
case "$id" in
  ''|null) echo "创建后读不到 id：$(cat /tmp/mail-created.json)"; exit 1 ;;
esac
echo "已登记 Email 通知并发了测试信（id=$id）：$from -> $owner 经 $host:$port 明文不认证"
