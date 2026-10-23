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

# ---------------- auth + tenancy ----------------
log "testing OCI CLI auth..."
if ! oci iam region list --output json >/tmp/regions.json 2>/tmp/regions.err; then
  echo "--- oci stderr ---"; cat /tmp/regions.err
  die "OCI CLI is not authenticated in this shell"
fi
log "auth OK ($(jq -r '.data|length' /tmp/regions.json) regions visible)"

C="${TENANCY:-}"
if [ -z "$C" ] && [ -f "$HOME/.oci/config" ]; then
  C=$(grep -m1 '^tenancy=' "$HOME/.oci/config" | cut -d= -f2- | tr -d ' \r' || true)
fi
if [ -z "$C" ]; then
  C=$(oci iam compartment list --all --query 'data[0]."compartment-id"' --raw-output 2>/dev/null || true)
fi
if [ -z "$C" ]; then
  C=$(oci iam region-subscription list --output json 2>/dev/null | jq -r '.data[0]."tenancy-id" // empty' || true)
fi
if [ -z "$C" ]; then
  C=$(oci iam tenancy list --output json 2>/dev/null | jq -r '.data[0].id // empty' || true)
fi
if [ -z "$C" ] && [ -f "$HOME/.oci/config" ]; then
  echo "--- ~/.oci/config keys (values hidden) ---"
  sed -E 's/^([a-z_]+)=.*/\1=***/' "$HOME/.oci/config" 2>/dev/null || true
fi
[ -n "$C" ] && [ "$C" != "null" ] || die "could not resolve tenancy OCID (pass TENANCY=ocid1.tenancy... )"
log "tenancy=$C"

REGION="${REGION:-$(grep -m1 '^region=' "$HOME/.oci/config" 2>/dev/null | cut -d= -f2- | tr -d ' \r' || true)}"
[ -n "$REGION" ] || REGION=$(oci iam region-subscription list --output json 2>/dev/null | jq -r '.data[0]."region-name" // empty')
log "region=${REGION:-<default>}"

AD=$(oci iam availability-domain list -c "$C" --output json | jq -r '.data[0].name')
[ -n "$AD" ] && [ "$AD" != "null" ] || die "could not resolve availability domain"
log "AD=$AD"

# ---------------- already deployed? ----------------
EXIST=$(oci compute instance list -c "$C" --display-name "${PREFIX}-server" --output json 2>/dev/null \
        | jq -r '[.data[]|select(.id != null)][0].id // empty')
if [ -n "$EXIST" ]; then
  IP=$(oci compute instance list-vnics --instance-id "$EXIST" --output json | jq -r '.data[0]."public-ip" // empty')
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

SUBNET=$(oci network subnet list -c "$C" --vcn-id "$VCN" --output json \
         | jq -r '.data[]|select(."display-name"=="farm-subnet")|.id' | head -1)
if [ -z "$SUBNET" ] || [ "$SUBNET" = "null" ]; then
  log "creating subnet farm-subnet 10.0.1.0/24..."
  SUBNET=$(oci network subnet create -c "$C" --vcn-id "$VCN" --cidr-block 10.0.1.0/24 \
           --display-name farm-subnet --dns-label farmsub \
           --route-table-id "$RT" --security-list-ids "[\"$SL\"]" \
           --wait-for-state AVAILABLE --output json | jq -r .data.id)
fi
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

# ---------------- launch (retry on capacity) ----------------
log "launching ${OCPUS} OCPU / ${MEMGB}GB VM.Standard.A1.Flex (retrying on capacity)..."
INST=""
for i in $(seq 1 240); do
  if oci compute instance launch -c "$C" --availability-domain "$AD" --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMGB}" \
      --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
      --display-name "${PREFIX}-server" --metadata file:///tmp/meta.json \
      --wait-for-state RUNNING --output json > /tmp/inst.json 2>/tmp/err; then
    INST=$(jq -r .data.id /tmp/inst.json); break
  fi
  reason=$(grep -io 'Out of host capacity\|LimitExceeded\|InternalError\|InvalidParameter\|NotAuthenticated\|Forbidden' /tmp/err | head -1)
  echo "[$(ts)] attempt $i: ${reason:-unknown error}"
  sleep 20
done
if [ -z "$INST" ]; then echo "[!] launch failed. Last error:"; tail -20 /tmp/err; exit 1; fi

IP=$(oci compute instance list-vnics --instance-id "$INST" --output json | jq -r '.data[0]."public-ip" // empty')
echo
echo "================ DEPLOYED ================"
echo "Instance OCID    : $INST"
echo "Server public IP : ${IP:-<pending>}"
echo "SSH              : ssh -i ~/.ssh/oci_farm ubuntu@${IP:-<ip>}"
echo "Bootstrap runs   : ~3-5 min on first boot"
echo "Then             : bash /opt/farm/farm.sh start 8"
echo "========================================="
