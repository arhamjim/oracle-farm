#!/usr/bin/env bash
# Oracle Always-Free ARM: Android farm (redroid) + 24/7 agent.
# One-shot deploy -- run in Oracle Cloud Shell (already authenticated).
# Idempotent: safe to re-run. Reuses hermes-vcn but adds its own
# route table / security list / subnet so nothing existing is modified.
set -uo pipefail
trap 'echo "[!] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

ts()  { date +%H:%M:%S; }
log() { echo "[$(ts)] $*"; }
die() { echo "[!] $*" >&2; exit 1; }

echo "=========================================================="
echo " Oracle farm deploy  $(date -u +%FT%TZ)"
echo "=========================================================="

for t in oci jq base64 curl; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done

SSH_PUBKEY="${SSH_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKOGwprO9aJX5q2kkptbJZkto21s6xO2s+1CDOewtjEv oci-farm}"
PREFIX="${PREFIX:-farm}"; OCPUS="${OCPUS:-4}"; MEMGB="${MEMGB:-24}"

# ---------------- auth + tenancy (verified) ----------------
log "testing OCI CLI auth..."
if ! oci iam region list --output json >/tmp/regions.json 2>/tmp/regions.err; then
  echo "--- oci stderr ---"; cat /tmp/regions.err
  die "OCI CLI is not authenticated in this shell"
fi
log "auth OK ($(jq -r '.data|length' /tmp/regions.json) regions visible)"

CONF="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
CONF_TENANCY=""
if [ -f "$CONF" ]; then
  CONF_TENANCY=$(grep -m1 -Ei '^[[:space:]]*tenancy[[:space:]]*=' "$CONF" | cut -d= -f2- | tr -d ' "\r' || true)
fi

REGION="${REGION:-${OCI_REGION:-}}"
if [ -z "$REGION" ] && [ -f "$CONF" ]; then
  REGION=$(grep -m1 -Ei '^[[:space:]]*region[[:space:]]*=' "$CONF" | cut -d= -f2- | tr -d ' \r' || true)
fi
log "region=${REGION:-<cli default>}"

# Try every tenancy candidate until one actually authorizes. A wrong OCID
# returns 404 NotAuthorizedOrNotFound, which is indistinguishable from a typo,
# so we validate rather than trust.
C=""; AD=""
for cand in ${EXPLICIT_TENANCY:-} ${OCI_TENANCY:-} ${TENANCY:-} ${CONF_TENANCY:-}; do
  [ -n "$cand" ] || continue
  ad=$(oci iam availability-domain list -c "$cand" --output json 2>/dev/null | jq -r '.data[0].name // empty' || true)
  if [ -n "$ad" ]; then
    C="$cand"; AD="$ad"
    log "tenancy=$C  (verified)"
    break
  fi
  log "tenancy candidate rejected: ${cand:0:72}..."
done
if [ -z "$C" ]; then
  echo "--- candidates tried ---"
  echo "OCI_TENANCY=${OCI_TENANCY:-<unset>}"
  echo "TENANCY=${TENANCY:-<unset>}"
  echo "config($CONF)=${CONF_TENANCY:-<unset>}"
  [ -f "$CONF" ] && { echo "--- config keys ---"; sed -E 's/^([a-zA-Z_]+)[[:space:]]*=.*/\1=***/' "$CONF"; }
  die "no working tenancy OCID (pass EXPLICIT_TENANCY=ocid1.tenancy...)"
fi
log "AD=$AD"

# ---------------- already deployed? ----------------
# ---------------- already deployed? ----------------
EXIST=$(oci compute instance list -c "$C" --display-name "${PREFIX}-server" --output json 2>/dev/null \
        | jq -r '[.data[]|select(."lifecycle-state"=="RUNNING" or ."lifecycle-state"=="PROVISIONING" or ."lifecycle-state"=="STARTING" or ."lifecycle-state"=="STOPPED")][0].id // empty' 2>/dev/null || true)
EXIST="${EXIST:-}"
if [ -n "$EXIST" ] && [ "$EXIST" != "null" ]; then
  IP=$(oci compute instance list-vnics --instance-id "$EXIST" --output json 2>/dev/null | jq -r '.data[0]."public-ip" // empty' 2>/dev/null || true)
  log "instance already exists: $EXIST"
  echo
  echo "================ ALREADY DEPLOYED ================"
  echo "Server public IP : ${IP:-<pending>}"
  echo "SSH              : ssh -i ~/.ssh/oci_farm ubuntu@${IP:-<ip>}"
  echo "=================================================="
  exit 0
fi

# ---------------- cloud-init ----------------
cat > /tmp/ci.yaml <<'CIEOF'
#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl
  - git
  - python3
  - python3-pip
  - tmux
  - ufw
  - jq
  - docker.io
  - adb
write_files:
  - path: /etc/modules-load.d/redroid.conf
    content: |
      binder_linux
      ashmem_linux
  - path: /etc/modprobe.d/redroid.conf
    content: |
      options binder_linux devices=binder,hwbinder,vndbinder
  - path: /opt/farm/farm.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      IMAGE="${IMAGE:-redroid/redroid:12.0.0_arm64-latest}"
      BASE_ADB="${BASE_ADB:-5555}"
      cmd="${1:-}"
      case "$cmd" in
        start)
          n="${2:-1}"
          for i in $(seq 0 $((n-1))); do
            name="redroid_$i"; port=$((BASE_ADB+i)); dir="$HOME/redroid/$name"
            mkdir -p "$dir"; docker rm -f "$name" >/dev/null 2>&1 || true
            docker run -itd --rm --name "$name" --privileged -v "$dir":/data -p "${port}:5555" "$IMAGE" >/dev/null
            echo "$name  adb=localhost:$port"
          done ;;
        stop)   ids=$(docker ps -aq --filter "name=redroid_"); [ -n "$ids" ] && docker rm -f $ids || true ;;
        status) docker ps --filter "name=redroid_" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
        adb)    n="${2:-0}"; adb connect "localhost:$((BASE_ADB+n))" ;;
        logs)   n="${2:-0}"; docker logs "redroid_$n" ;;
        *) echo "usage: $0 {start N|stop|status|adb N|logs N}" ;;
      esac
runcmd:
  - [ bash, -lc, "usermod -aG docker ubuntu || true" ]
  - [ bash, -lc, "systemctl enable --now docker" ]
  - [ bash, -lc, "apt-get install -y linux-modules-extra-$(uname -r) || true" ]
  - [ bash, -lc, "depmod -a; modprobe binder_linux devices=binder,hwbinder,vndbinder || true; modprobe ashmem_linux || true" ]
  - [ bash, -lc, "{ uname -r; lsmod | grep -E 'binder|ashmem' || echo 'binder/ashmem NOT loaded'; } > /opt/farm/preflight.log 2>&1" ]
  - [ bash, -lc, "ufw allow 22/tcp; ufw --force enable || true" ]
  - [ bash, -lc, "sysctl -w net.ipv4.ip_forward=1; echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-farm.conf" ]
  - [ bash, -lc, "curl -fsSL https://tailscale.com/install.sh | sh || true" ]
  - [ bash, -lc, "mkdir -p /home/ubuntu/redroid; chown -R ubuntu:ubuntu /home/ubuntu/redroid" ]
  - [ bash, -lc, "touch /opt/farm/READY" ]
final_message: "farm bootstrap complete"
CIEOF
log "cloud-init prepared ($(wc -c < /tmp/ci.yaml) bytes)"

# ---------------- network: reuse VCN, add own pieces ----------------
VCN=$(oci network vcn list -c "$C" --output json | jq -r '.data[]|select(."display-name"=="hermes-vcn")|.id' | head -1)
[ -n "$VCN" ] && [ "$VCN" != "null" ] || VCN=$(oci network vcn list -c "$C" --output json | jq -r '.data[0].id // empty')
[ -n "$VCN" ] && [ "$VCN" != "null" ] || die "no VCN in this tenancy/region"
log "VCN=$VCN"

IGW=$(oci network internet-gateway list -c "$C" --vcn-id "$VCN" --output json | jq -r '.data[0].id // empty')
if [ -z "$IGW" ] || [ "$IGW" = "null" ]; then
  log "creating internet gateway..."
  IGW=$(oci network internet-gateway create -c "$C" --vcn-id "$VCN" --is-enabled true \
        --display-name "${PREFIX}-igw" --wait-for-state AVAILABLE --output json | jq -r .data.id)
fi
log "IGW=$IGW"

RT=$(oci network route-table list -c "$C" --vcn-id "$VCN" --output json \
     | jq -r --arg n "${PREFIX}-rt" '.data[]|select(."display-name"==$n)|.id' | head -1)
if [ -z "$RT" ] || [ "$RT" = "null" ]; then
  log "creating route table ${PREFIX}-rt..."
  printf '[{"destination":"0.0.0.0/0","networkEntityId":"%s"}]' "$IGW" > /tmp/route.json
  RT=$(oci network route-table create -c "$C" --vcn-id "$VCN" --display-name "${PREFIX}-rt" \
       --route-rules file:///tmp/route.json --wait-for-state AVAILABLE --output json | jq -r .data.id)
fi
log "RT=$RT"

SL=$(oci network security-list list -c "$C" --vcn-id "$VCN" --output json \
     | jq -r --arg n "${PREFIX}-sl" '.data[]|select(."display-name"==$n)|.id' | head -1)
if [ -z "$SL" ] || [ "$SL" = "null" ]; then
  log "creating security list ${PREFIX}-sl..."
  cat > /tmp/ingress.json <<'EOJ'
[{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
 {"source":"10.0.0.0/16","protocol":"all"}]
EOJ
  echo '[{"destination":"0.0.0.0/0","protocol":"all"}]' > /tmp/egress.json
  SL=$(oci network security-list create -c "$C" --vcn-id "$VCN" --display-name "${PREFIX}-sl" \
       --ingress-security-rules file:///tmp/ingress.json \
       --egress-security-rules file:///tmp/egress.json \
       --wait-for-state AVAILABLE --output json | jq -r .data.id)
fi
log "SL=$SL"

SUBNET=$(oci network subnet list -c "$C" --vcn-id "$VCN" --output json 2>/dev/null \
         | jq -r '.data[]|select(."display-name"=="farm-subnet")|.id' 2>/dev/null | head -1 || true)
SUBNET="${SUBNET:-}"
if [ -z "$SUBNET" ] || [ "$SUBNET" = "null" ]; then
  USED=$(oci network subnet list -c "$C" --vcn-id "$VCN" --output json 2>/dev/null | jq -r '.data[]."cidr-block"' 2>/dev/null || true)
  log "existing subnets: $(echo "$USED" | tr '\n' ' ')"
  SUBNET=""
  for oct in 100 101 102 110 120 130 140 150 160 170 180 190 200 210 220 230 240 250 2 3 4 5 6 7 8 9 10 20 30 40 50 60 70 80 90; do
    cidr="10.0.${oct}.0/24"
    if echo "$USED" | grep -qx "$cidr"; then continue; fi
    log "trying subnet farm-subnet $cidr ..."
    if SUBNET=$(oci network subnet create -c "$C" --vcn-id "$VCN" --cidr-block "$cidr" \
         --display-name farm-subnet --dns-label "farm${oct}" \
         --route-table-id "$RT" --security-list-ids "[\"$SL\"]" \
         --wait-for-state AVAILABLE --output json 2>/tmp/suberr | jq -r '.data.id // empty' 2>/dev/null); then
      [ -n "$SUBNET" ] && [ "$SUBNET" != "null" ] && break
    fi
    SUBNET=""
    log "  -> $(grep -o '"message": "[^"]*"' /tmp/suberr 2>/dev/null | head -1 || echo 'failed, trying next cidr')"
  done
fi
[ -n "$SUBNET" ] && [ "$SUBNET" != "null" ] || { echo "[!] could not create or find a subnet"; tail -5 /tmp/suberr 2>/dev/null; exit 1; }
log "SUBNET=$SUBNET"
# ---------------- image ----------------
log "looking up Ubuntu 24.04 aarch64 image..."
IMGS=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex --output json 2>/dev/null)
[ -n "$IMGS" ] || IMGS=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --output json 2>/dev/null)
[ -n "$IMGS" ] || IMGS='{"data":[]}'
IMG=$(echo "$IMGS" | jq -r '[.data[]|select(."display-name"|test("24.04"))|select(."display-name"|test("aarch64"))][0].id // empty')
[ -n "$IMG" ] || IMG=$(echo "$IMGS" | jq -r '[.data[]|select(."display-name"|test("22.04"))|select(."display-name"|test("aarch64"))][0].id // empty')
[ -n "$IMG" ] || IMG=$(echo "$IMGS" | jq -r '.data[0].id // empty')
[ -n "$IMG" ] && [ "$IMG" != "null" ] || die "no aarch64 Ubuntu image found"
log "IMAGE=$IMG"

UD=$(base64 -w0 /tmp/ci.yaml)
jq -n --arg k "$SSH_PUBKEY" --arg u "$UD" '{ssh_authorized_keys:$k, user_data:$u}' > /tmp/meta.json

# ---------------- launch (retry on capacity, ladder down if scarce) ----------------
# ---------------- launch (429-aware backoff, capacity ladder) ----------------
MAX_TRIES="${MAX_TRIES:-240}"
[ "${ONCE:-0}" = "1" ] && MAX_TRIES=1
INST=""; i=0; rate=0
while [ -z "$INST" ]; do
  i=$((i+1))
  if [ "$i" -gt "$MAX_TRIES" ]; then break; fi
  if   [ "$i" -le 40 ]; then cap=4.0; mem=24.0
  elif [ "$i" -le 80 ]; then cap=2.0; mem=12.0
  else                       cap=1.0; mem=6.0
  fi
  # keep total request rate low; OCI throttles bursts hard
  oci compute instance launch -c "$C" --availability-domain "$AD" --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\":$cap,\"memoryInGBs\":$mem}" \
      --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
      --display-name "${PREFIX}-server" --metadata file:///tmp/meta.json \
      --output json > /tmp/inst.json 2>/tmp/err
  rc=$?
  if [ $rc -eq 0 ]; then
    INST=$(jq -r '.data.id // empty' /tmp/inst.json 2>/dev/null || true)
    [ -n "$INST" ] && break
  fi
  INST=""
  reason=$(grep -oE 'TooManyRequests|Too many requests|Out of host capacity|LimitExceeded|InternalError|InvalidParameter|NotAuthorizedOrNotFound|Forbidden|QuotaExceeded' /tmp/err 2>/dev/null | head -1 || true)
  detail=$(grep -o '"message": "[^"]*"' /tmp/err 2>/dev/null | head -1 | cut -c12-140 || true)
  echo "[$(ts)] attempt $i/${MAX_TRIES} (${cap}ocpu/${mem}GB): ${detail:-${reason:-unknown error}}"
  case "$reason" in
    InvalidParameter|NotAuthorizedOrNotFound|Forbidden|QuotaExceeded)
      echo "[!] fatal launch error, not retrying:"; tail -25 /tmp/err; exit 1 ;;
    TooManyRequests|"Too many requests")
      rate=$((rate+1))
      w=$(( 120 * rate )); [ "$w" -gt 600 ] && w=600
      w=$(( w + RANDOM % 30 ))
      echo "[$(ts)] rate limited (hit #$rate) -> cooling down ${w}s"
      sleep "$w" ;;
    *)
      sleep 20 ;;
  esac
done
[ -n "$INST" ] || { echo "[!] gave up after $i attempts. Last error:"; tail -25 /tmp/err; exit 1; }

# wait for RUNNING without hammering the API
log "instance created, waiting for RUNNING..."
for _ in $(seq 1 60); do
  st=$(oci compute instance get --instance-id "$INST" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
  [ "$st" = "RUNNING" ] && break
  case "$st" in PROVISIONING|STARTING|"") sleep 10 ;; *) break ;; esac
done
IP=$(oci compute instance list-vnics --instance-id "$INST" --output json 2>/dev/null | jq -r '.data[0]."public-ip" // empty' 2>/dev/null || true)
SHAPE=$(jq -r '.data."shape-config" | "\(.ocpus) OCPU / \(."memory-in-gbs") GB"' /tmp/inst.json 2>/dev/null || echo "")
echo
echo "================ DEPLOYED ================"
echo "Instance OCID    : $INST"
echo "Shape            : ${SHAPE:-VM.Standard.A1.Flex}"
echo "Server public IP : ${IP:-<pending>}"
echo "SSH              : ssh -i ~/.ssh/oci_farm ubuntu@${IP:-<ip>}"
echo "Bootstrap runs   : ~3-5 min on first boot"
echo "Then             : bash /opt/farm/farm.sh start 8"
echo "========================================="
