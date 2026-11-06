# shellcheck shell=bash
# scripts/smoke.sh 与 e2e/smoke.sh 共用的插件探针。
# Prowlarr：sso=proxy；External 模式下应用侧零鉴权、没有用户体系，主人身份由云吞网关保证。
# API 要 X-Api-Key：从容器里的 /config/config.xml 读。
export IDENTITY_NA=1
export SMOKE_NOTE="Prowlarr 是单用户应用（External 模式无应用侧登录页）；没有可断言的用户身份接口，免二次登录由云吞网关会话保证。"

web_assert() { grep -qi 'prowlarr'; }   # 标准输入：SPA 首页 HTML 含应用名

probe_env() {
  echo "${E2E_INSTANCE:-${SMOKE_INSTANCE:-}}"
}

probe_slug() {
  echo "${E2E_SLUG:-${SMOKE_SLUG:-}}"
}

prowlarr_container() {
  printf 'wonton-%s--%s--prowlarr' "$(probe_env)" "$(probe_slug)"
}

prowlarr_key() { # 容器里 config.xml 的 ApiKey
  local key
  key="$(docker exec "$(prowlarr_container)" sh -c \
    "sed -n 's:.*<ApiKey>\\(.*\\)</ApiKey>.*:\\1:p' /config/config.xml" 2>/dev/null)"
  [[ -n "$key" ]] || { echo "容器里读不到 ApiKey"; return 1; }
  printf '%s' "$key"
}

prowlarr_api() { # <方法> <路径> [请求体]：容器内直调应用 API，带 X-Api-Key
  local method="$1" path="$2" body="${3:-}" key cid
  cid="$(prowlarr_container)" || return 1
  key="$(prowlarr_key)" || return 1
  local -a args=(--noproxy '*' -fsS -X "$method" -H "X-Api-Key: $key")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  docker exec "$cid" curl "${args[@]}" "http://127.0.0.1:9696/api/v1/$path"
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
  local list tpl payload created id
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
  # 先 disable 创建，再 forceSave 启用，登记本身不碰网。
  payload="$(jq -c --arg n "$SMOKE_INDEXER" '
    {name: $n, enable: false, protocol: "torrent", implementation: .implementation,
     configContract: .configContract, priority: (.priority // 1),
     appProfileId: (if ((.appProfileId // 0) > 0) then .appProfileId else 1 end),
     tags: [],
     fields: [.fields[]
              | if .name == "baseUrl" and ((.value // "") == "") then .value = .selectOptions[0].value
                else . end]}' <<<"$tpl")" ||
    { echo "组装索引器请求失败"; return 1; }
  created="$(prowlarr_api POST indexer "$payload")" || { echo "登记索引器失败"; return 1; }
  id="$(jq -r '.id // empty' <<<"$created")"
  [[ -n "$id" ]] || { echo "登记后读不到 id：$(head -c 200 <<<"$created")"; return 1; }
  enabled="$(jq -c --argjson id "$id" '.id = $id | .enable = true' <<<"$payload")"
  prowlarr_api PUT "indexer?forceSave=true" "$enabled" >/dev/null || { echo "启用索引器失败（id=$id）"; return 1; }
  echo "已登记索引器 $SMOKE_INDEXER（id=$id，TorrentsCSV，已启用）"
}

data_check() { # 升级/重装后：索引器还在，还是登记时的实现
  local list item
  list="$(prowlarr_api_ready)" || return 1
  item="$(jq -c --arg n "$SMOKE_INDEXER" '[.[] | select(.name == $n)][0] // empty' <<<"$list")"
  [[ -n "$item" ]] || { echo "索引器 $SMOKE_INDEXER 不见了：$(head -c 200 <<<"$list")"; return 1; }
  jq -e '.implementation == "TorrentsCSV" and .enable == true' <<<"$item" >/dev/null ||
    { echo "索引器被改动：$item"; return 1; }
  echo "索引器 $SMOKE_INDEXER 还在（$(jq -r '.implementation' <<<"$item")）"
}
