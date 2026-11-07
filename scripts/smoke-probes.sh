# shellcheck shell=bash
# scripts/smoke.sh 与 e2e/smoke.sh 共用的插件探针。
# 钩子可用面（负责人 2026-11-07 定）：变量 SMOKE_STATE（数据标记，e2e 是文件、dev.sh probes 是目录）、
# SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE；助手 web_get、dweb。
# Prowlarr：sso=none + 应用自带 Forms 认证（主人首次打开自己设管理员）。
# identity_check 模拟首次打开：经应用 API 开启 Forms 并建 SMOOKE_OWNER 的管理员账号，再断言应用认出主人。
# API 要 X-Api-Key：认证未开时从 /initialize.json 取；开了先 POST /login（表单），应用 Cookie 落在 dweb
# 的会话 jar 里，再取 initialize.json。凭据与数据标记都写在标记文件里，按行分键。
web_assert() { grep -qi '<title>Prowlarr'; }   # 标准输入：SPA 首页 HTML 的标题

prowlarr_marker() { # 标记文件：SMOKE_STATE 是文件就用它，是目录就放里面（dev.sh probes 的 .wonton）
  if [[ -n "${SMOKE_STATE:-}" && -d "$SMOKE_STATE" ]]; then
    printf '%s/prowlarr-credentials' "$SMOKE_STATE"
  elif [[ -n "${SMOKE_STATE:-}" ]]; then
    printf '%s' "$SMOKE_STATE"
  else
    echo "SMOKE_STATE 没设置"; return 1
  fi
}

prowlarr_cred() { # <键>：标记里的单项
  local m
  m="$(prowlarr_marker)" || return 1
  [[ -f "$m" ]] || return 1
  sed -n "s/^$1=//p" "$m" | tail -1
}

prowlarr_marker_set() { # <键> <值>：改写标记里的一项，保留其它行
  local m
  m="$(prowlarr_marker)" || return 1
  if [[ -f "$m" ]] && grep -q "^$1=" "$m"; then
    sed -i "s/^$1=.*/$1=$2/" "$m"
  else
    printf '%s=%s\n' "$1" "$2" >>"$m"
  fi
}

prowlarr_login() { # 用标记里的凭据走应用登录；应用 Cookie 存进 dweb 的会话 jar
  local u p
  u="$(prowlarr_cred username)"
  p="$(prowlarr_cred password)"
  [[ -n "$u" && -n "$p" ]] || { echo "标记里没有凭据，登录不了已启用认证的实例"; return 1; }
  dweb "/login" -X POST --data-urlencode "username=$u" --data-urlencode "password=$p" >/dev/null ||
    { echo "登录请求失败"; return 1; }
}

prowlarr_key() { # 应用的 X-Api-Key：认证没开直接取 initialize.json，开了先登录
  local page key
  if page="$(dweb /initialize.json 2>/dev/null)"; then
    key="$(jq -r '.apiKey // empty' <<<"$page" 2>/dev/null)"
    if [[ -n "$key" && "$key" != null ]]; then printf '%s' "$key"; return 0; fi
  fi
  prowlarr_login || return 1
  page="$(dweb /initialize.json)" || { echo "登录后仍取不到 /initialize.json"; return 1; }
  key="$(jq -r '.apiKey // empty' <<<"$page" 2>/dev/null)"
  [[ -n "$key" && "$key" != null ]] || { echo "initialize.json 里没有 apiKey"; return 1; }
  printf '%s' "$key"
}

prowlarr_api() { # <方法> <路径> [请求体]：经网关调应用 API，带 X-Api-Key
  local method="$1" path="$2" body="${3:-}" key args=()
  key="$(prowlarr_key)" || return 1
  args+=(-X "$method" -H "X-Api-Key: $key")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  web_get "/api/v1/$path" "${args[@]}"
}

prowlarr_api_ready() { # 等 API 就绪，就绪后把 GET /indexer 的结果打到标准输出
  local out
  for _ in $(seq 1 20); do
    if out="$(prowlarr_api GET indexer)"; then
      printf '%s' "$out"
      return 0
    fi
    sleep 3
  done
  echo "Prowlarr 的 API 一直没就绪"
  return 1
}

SMOKE_INDEXER="wonton-smoke"

identity_check() { # sso:none 约定：首次打开设管理员，断言应用认出的管理员是主人
  local page key auth body p
  key="$(prowlarr_key)" || { echo "拿不到应用 API 钥匙：认证已开但标记里没有凭据"; return 1; }
  page="$(prowlarr_api GET config/host)" || { echo "读应用设置失败"; return 1; }
  auth="$(jq -r '.authenticationMethod // empty' <<<"$page")"
  if [[ "$auth" == "none" ]]; then
    # 首次打开：设 Forms 认证并建管理员（应用后端 Upsert 建号），口令只存冒烟标记
    p="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    body="$(jq -c --arg u "$SMOKE_OWNER" --arg p "$p" \
      '.authenticationMethod = "forms" | .username = $u | .password = $p | .passwordConfirmation = $p' <<<"$page")"
    prowlarr_api PUT config/host "$body" >/dev/null || { echo "开启 Forms 认证失败"; return 1; }
    prowlarr_marker_set username "$SMOKE_OWNER" && prowlarr_marker_set password "$p" ||
      echo "凭据写不进标记（后续探测会重新走登录路径）"
  fi
  key="$(prowlarr_key)" || { echo "认证开启后拿不到钥匙"; return 1; }
  page="$(prowlarr_api GET config/host)" || { echo "读应用设置失败"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.authenticationMethod == "forms" and .username == $u' <<<"$page" >/dev/null ||
    { echo "应用认出的管理员不是主人 $SMOKE_OWNER：$(head -c 200 <<<"$page")"; return 1; }
}

data_write() { # 登记一个公开免凭据的索引器（TorrentsCSV），作为要保住的用户数据
  local list tpl payload created enabled id out
  list="$(prowlarr_api_ready)" || return 1
  # 幂等：先删掉上次留下的同名索引器，再登记一个新的。
  local old
  old="$(jq -r --arg n "$SMOKE_INDEXER" '[.[] | select(.name == $n)][0].id // empty' <<<"$list")"
  if [[ -n "$old" ]]; then
    prowlarr_api DELETE "indexer/$old" >/dev/null || { echo "删旧索引器失败（id=$old）"; return 1; }
  fi
  tpl="$(prowlarr_api GET indexer/schema | jq -c '[.[] | select(.implementation == "TorrentsCSV")][0] // empty')" ||
    { echo "读 indexer schema 失败"; return 1; }
  [[ -n "$tpl" ]] || { echo "schema 里没有 TorrentsCSV 实现"; return 1; }
  # enable=true 的创建和更新都会触发应用的连通测试，依赖测试机器到索引站的网络（与插件无关）；
  # 先 disable 创建，再 forceSave 启用，登记本身不碰网。Priority 须在 1-50、appProfileId 须 >0，
  # schema 默认是 0，都要显式透传。
  payload="$(jq -c --arg n "$SMOKE_INDEXER" '
    {name: $n, enable: false, protocol: "torrent", implementation: .implementation,
     configContract: .configContract, priority: (.priority // 1),
     appProfileId: (if ((.appProfileId // 0) > 0) then .appProfileId else 1 end),
     tags: [],
     fields: [.fields[]
              | if .name == "baseUrl" and ((.value // "") == "") then .value = .selectOptions[0].value
                else . end]}' <<<"$tpl")" ||
    { echo "组装索引器请求失败"; return 1; }
  if ! out="$(prowlarr_api POST indexer "$payload")"; then
    echo "登记索引器失败：$out"; return 1
  fi
  created="$out"
  id="$(jq -r '.id // empty' <<<"$created")"
  [[ -n "$id" ]] || { echo "登记后读不到 id：$(head -c 200 <<<"$created")"; return 1; }
  enabled="$(jq -c --argjson id "$id" '.id = $id | .enable = true' <<<"$payload")"
  if ! out="$(prowlarr_api PUT "indexer?forceSave=true" "$enabled")"; then
    echo "启用索引器失败（id=$id）：$out"; return 1
  fi
  # 数据标记：data_check 按这里写下的内容核对。
  if ! prowlarr_marker_set name "$SMOKE_INDEXER"; then echo "数据标记写不进 $SMOKE_STATE"; return 1; fi
  if ! prowlarr_marker_set implementation "$(jq -r '.implementation' <<<"$created")"; then
    echo "数据标记写不进 $SMOKE_STATE"; return 1
  fi
  echo "已登记索引器 $SMOKE_INDEXER（id=$id，TorrentsCSV，已启用）"
}

data_check() { # 升级/重装后：标记里的索引器还在，还是登记时的实现
  local marker_name marker_impl list item
  marker_name="$(prowlarr_cred name)"
  marker_impl="$(prowlarr_cred implementation)"
  [[ -n "$marker_name" ]] || { echo "标记里没有数据（data_write 没跑？）"; return 1; }
  list="$(prowlarr_api_ready)" || return 1
  item="$(jq -c --arg n "$marker_name" '[.[] | select(.name == $n)][0] // empty' <<<"$list")"
  [[ -n "$item" ]] || { echo "索引器 $marker_name 不见了：$(head -c 200 <<<"$list")"; return 1; }
  jq -e --arg i "$marker_impl" '.implementation == $i and .enable == true' <<<"$item" >/dev/null ||
    { echo "索引器被改动：$item"; return 1; }
  echo "索引器 $marker_name 还在（$(jq -r '.implementation' <<<"$item")）"
}
