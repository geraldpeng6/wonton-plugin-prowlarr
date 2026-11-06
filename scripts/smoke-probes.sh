# shellcheck shell=bash
# scripts/smoke.sh 与 e2e/smoke.sh 共用的插件探针。
# 钩子可用面（负责人 2026-11-07 定）：变量 SMOKE_STATE（数据标记文件，data_write 覆盖写、data_check 读）、
# SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE；助手 web_get、dweb。
# Prowlarr：sso=proxy；External 模式下应用侧零鉴权、没有用户体系，主人身份由云吞网关保证。
# API 要 X-Api-Key：从应用自己的 /initialize.json 拿（UI 策略放行、经网关的会话请求）。
export IDENTITY_NA=1
export SMOKE_NOTE="Prowlarr 是单用户应用（External 模式无应用侧登录页）；没有可断言的用户身份接口，免二次登录由云吞网关会话保证。"

web_assert() { grep -qi 'prowlarr'; }   # 标准输入：SPA 首页 HTML 含应用名

prowlarr_key() { # initialize.json 的 apiKey
  local page key
  page="$(dweb /initialize.json)" || { echo "取 /initialize.json 失败：$page"; return 1; }
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
  out="$(prowlarr_api PUT "indexer?forceSave=true" "$enabled")" || {
    echo "启用索引器失败（id=$id）：$out"; return 1; }
  # 数据标记：data_check 按这里写下的内容核对（覆盖写）。
  printf 'name=%s\nimplementation=%s\n' "$SMOKE_INDEXER" "$(jq -r '.implementation' <<<"$created")" >"$SMOKE_STATE"
  echo "已登记索引器 $SMOKE_INDEXER（id=$id，TorrentsCSV，已启用）"
}

data_check() { # 升级/重装后：标记里的索引器还在，还是登记时的实现
  local marker_name marker_impl list item key
  [[ -f "$SMOKE_STATE" ]] || { echo "没有数据标记 $SMOKE_STATE（data_write 没跑？）"; return 1; }
  marker_name="$(sed -n 's/^name=//p' "$SMOKE_STATE" | tail -1)"
  marker_impl="$(sed -n 's/^implementation=//p' "$SMOKE_STATE" | tail -1)"
  [[ -n "$marker_name" ]] || { echo "数据标记里没有 name"; return 1; }
  list="$(prowlarr_api_ready)" || return 1
  item="$(jq -c --arg n "$marker_name" '[.[] | select(.name == $n)][0] // empty' <<<"$list")"
  [[ -n "$item" ]] || { echo "索引器 $marker_name 不见了：$(head -c 200 <<<"$list")"; return 1; }
  jq -e --arg i "$marker_impl" '.implementation == $i and .enable == true' <<<"$item" >/dev/null ||
    { echo "索引器被改动：$item"; return 1; }
  echo "索引器 $marker_name 还在（$(jq -r '.implementation' <<<"$item")）"
}
