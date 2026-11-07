#!/usr/bin/env bash
# torrent_client 能力接线的独立 e2e：验证 provision.sh 的三条路径（未接线跳过 / 登记 / 幂等不动），
# 以及登记出的下载客户端真的能从 Prowlarr 连上 qBittorrent。
# 单容器复现（真实首启的 Prowlarr + 真实 qBittorrent），不占验证栈名额；测完自动清理，宿主不留东西。
# 用法：bash scripts/capability-e2e.sh（要 Docker 和网络；qBittorrent 镜像按 compose 仓库同名标签拉取）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

IMG=linuxserver/prowlarr:2.7.0@sha256:431d7efebcef466e56adaa40a7a2fa2b0e85159a037b8bf465eaadbf0cf5bedf
QBT=qbittorrentofficial/qbittorrent-nox:5.2.1-1
NET=capability-e2e
P=capability-e2e-prowlarr
Q=capability-e2e-qbt
WORK=$(mktemp -d)

cleanup() {
  docker rm -f "$P" "$Q" 2>/dev/null || true
  docker network rm "$NET" 2>/dev/null || true
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
# 宿主 docker 客户端 config 里的 proxies 会注入所有容器（#121），连通测试会被 127.0.0.1 的代理劫持；全部剥掉。
mkdir -p "$WORK/docker-config"
if [[ -f "${DOCKER_CONFIG:-$HOME/.docker}/config.json" ]]; then
  jq 'del(.proxies)' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" >"$WORK/docker-config/config.json"
  export DOCKER_CONFIG="$WORK/docker-config"
fi
mkdir -p "$WORK/config" "$WORK/qbt/qBittorrent/config"

echo "== 1. 起 Prowlarr（真实首启，生成 config.xml）"
docker run -d --name "$P" --network "$NET" --network-alias prowlarr -e PUID=1000 -e PGID=1000 -e TZ=UTC \
  -v "$WORK/config:/config" "$IMG" >/dev/null
for i in $(seq 1 60); do
  if docker exec "$P" curl --noproxy '*' -fsS http://127.0.0.1:9696/ping >/dev/null 2>&1; then break; fi
  [ "$i" -lt 60 ] || { echo "Prowlarr 没起来"; docker logs "$P" | tail -20; exit 1; }
  sleep 2
done
echo "Prowlarr /ping OK"

echo "== 2. 起 qBittorrent（白名单放开 Prowlarr 实际所在网段，模拟核心来源免认证）"
PSUB=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$P" | xargs docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
echo "Prowlarr 网段：$PSUB"
cat > "$WORK/qbt/qBittorrent/config/qBittorrent.conf" <<EOF
[BitTorrent]
Session\DefaultSavePath=/downloads

[LegalNotice]
Accepted=true

[Meta]
MigrationVersion=8

[Preferences]
WebUI\Address=*
WebUI\AuthSubnetWhitelist=$PSUB
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\HostHeaderValidation=false
WebUI\LocalHostAuth=false
EOF
docker run -d --name "$Q" --network "$NET" --user 1000:1000 \
  -e QBT_WEBUI_PORT=8080 -e QBT_TORRENTING_PORT=51413 -e TZ=UTC \
  -v "$WORK/qbt:/config" "$QBT" >/dev/null
for i in $(seq 1 30); do
  if docker exec "$Q" curl --noproxy '*' -fsS http://127.0.0.1:8080/api/v2/app/version >/dev/null 2>&1; then break; fi
  [ "$i" -lt 30 ] || { echo "qBittorrent 没起来"; docker logs "$Q" | tail -20; exit 1; }
  sleep 2
done
echo "qBittorrent API OK"

echo "== 3. 未接线：变量为空 → 跳过"
docker run --rm --network "$NET" -e WONTON_TORRENT_CLIENT_URL= \
  -v "$WORK/config:/config:ro" -v "$PWD/provision.sh:/provision.sh:ro" \
  --entrypoint /bin/sh "$IMG" /provision.sh

echo "== 4. 接线：登记下载客户端（enable=true 时应用先测连通，通过才创建）"
docker run --rm --network "$NET" -e WONTON_TORRENT_CLIENT_URL=http://"$Q":8080 \
  -v "$WORK/config:/config:ro" -v "$PWD/provision.sh:/provision.sh:ro" \
  --entrypoint /bin/sh "$IMG" /provision.sh

key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$WORK/config/config.xml")
got=$(docker exec "$P" curl --noproxy '*' -fsS -H "X-Api-Key: $key" http://127.0.0.1:9696/api/v1/downloadclient) ||
  { echo "读 downloadclient 失败"; exit 1; }
host=$(jq -r '[.[] | select(.implementation == "QBittorrent")][0].fields[] | select(.name == "host") | .value' <<<"$got")
port=$(jq -r '[.[] | select(.implementation == "QBittorrent")][0].fields[] | select(.name == "port") | .value' <<<"$got")
if [ "$host" != "$Q" ] || [ "$port" != "8080" ]; then echo "登记的字段不对：host=$host port=$port"; exit 1; fi
echo "登记字段正确：$host:$port"

echo "== 5. 幂等：再跑一遍不动"
docker run --rm --network "$NET" -e WONTON_TORRENT_CLIENT_URL=http://"$Q":8080 \
  -v "$WORK/config:/config:ro" -v "$REPO/provision.sh:/provision.sh:ro" \
  --entrypoint /bin/sh "$IMG" /provision.sh
count=$(docker exec "$P" curl --noproxy '*' -fsS -H "X-Api-Key: $key" http://127.0.0.1:9696/api/v1/downloadclient \
  | jq '[.[] | select(.implementation == "QBittorrent")] | length')
[ "$count" = 1 ] || { echo "重复运行多出一个客户端：$count"; exit 1; }

echo "全部通过（连通性由第 4 步创建时的应用侧测试证明）"
