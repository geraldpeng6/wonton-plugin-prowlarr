#!/bin/sh
# 把 Email 通知接到核心的内部邮箱：装好就有，应用发的信转进收件人的 Wonton 私聊。
# 每次创建容器都会重跑，必须幂等：已有 Email 通知时不改用户配置。
# 建连接不做发信测试（?forceSave=true），测试信单独发一次、结果只记日志：
# 核心 SMTP 启动时抖一下不该让安装/升级失败，邮件是顺手的功能；连接本身建不了（API 报错）才失败。
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
# 收件人是主人的内部邮箱。触发器先全关着创建（Enable=false 时应用既不测连通也不校验字段，
# 创建这步只落存储），再用 ?forceSave=true 打开健康问题、健康恢复、应用更新：更新路径只在
# 没带 forceSave 时才发测试信，开发收信端没就绪也不会拖垮安装。抓取信默认不开（每抓一次发一封）。
payload=$(printf '%s' "$tpl" | jq -c --arg host "$host" --argjson port "$port" --arg from "$from" --arg to "$owner" '
  {
    name: "Wonton",
    implementation: .implementation,
    configContract: .configContract,
    tags: [],
    onGrab: false,
    onHealthIssue: false,
    onHealthRestored: false,
    onApplicationUpdate: false,
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

# 创建连接：应用报错（字段非法、重名）时带重试，重试满了带着应用的报错让安装失败。
code=""
i=0
while :; do
  code=$(curl --noproxy '*' -sS -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    -d "$payload" -o /tmp/mail-created.json -w '%{http_code}' "$api/notification?forceSave=true" || true)
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

# 打开触发器：?forceSave=true 让应用只校验字段、不发测试信。
enabled=$(jq -c --argjson id "$id" '.id = $id | .onHealthIssue = true | .onHealthRestored = true | .onApplicationUpdate = true' /tmp/mail-created.json)
code=""
i=0
while :; do
  code=$(curl --noproxy '*' -sS -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    -X PUT -d "$enabled" -o /tmp/mail-enabled.json -w '%{http_code}' "$api/notification?forceSave=true" || true)
  case "$code" in
    200 | 202) break ;;
  esac
  i=$((i + 1))
  [ "$i" -lt 3 ] || {
    echo "打开 Email 通知触发器失败（HTTP $code），应用返回："
    cat /tmp/mail-enabled.json 2>/dev/null || true
    exit 1
  }
  sleep 5
done

# 测试信只发一次、只记日志：发不出去（比如核心 SMTP 还没就绪）不影响安装，之后的信照常发。
code=$(curl --noproxy '*' -sS -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
  -d "$enabled" -o /tmp/mail-test.json -w '%{http_code}' "$api/notification/test" || true)
case "$code" in
  200) echo "已登记 Email 通知（id=$id）：$from -> $owner 经 $host:$port 明文不认证；测试信发出成功" ;;
  *)   echo "已登记 Email 通知（id=$id）：$from -> $owner 经 $host:$port 明文不认证；测试信没发出去（HTTP $code：$(head -c 200 /tmp/mail-test.json 2>/dev/null || true)），连接已建好，之后的信照常发" ;;
esac
