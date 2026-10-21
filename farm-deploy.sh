#!/usr/bin/env bash
# Oracle Always-Free ARM: Android farm (redroid) + 24/7 agent.
# One-shot deploy — run in Oracle Cloud Shell (already authenticated).
set -euo pipefail

SSH_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKOGwprO9aJX5q2kkptbJZkto21s6xO2s+1CDOewtjEv oci-farm'
PREFIX="${PREFIX:-farm}"; OCPUS="${OCPUS:-4}"; MEMGB="${MEMGB:-24}"

C=$(grep -m1 '^tenancy=' ~/.oci/config | cut -d= -f2-)
AD=$(oci iam availability-domain list -c "$C" --output json | jq -r '.data[0].name')
echo "[*] tenancy=$C"
echo "[*] AD=$AD"

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
  - scrcpy
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
        stop)   ids=$(docker ps -aq --filter "name=redroid_"); [ -n "$ids" ] && docker rm -f $ids ;;
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
  - [ bash, -lc, "lsmod | grep -E 'binder|ashmem' >> /opt/farm/preflight.log; uname -r >> /opt/farm/preflight.log" ]
  - [ bash, -lc, "ufw allow 22/tcp; ufw --force enable || true" ]
  - [ bash, -lc, "sysctl -w net.ipv4.ip_forward=1; echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-farm.conf" ]
  - [ bash, -lc, "curl -fsSL https://tailscale.com/install.sh | sh || true" ]
  - [ bash, -lc, "mkdir -p /home/ubuntu/redroid; chown -R ubuntu:ubuntu /home/ubuntu/redroid" ]
final_message: "farm bootstrap complete"
CIEOF

# ---------------- network (reuse hermes-vcn) ----------------
VCN=$(oci network vcn list -c "$C" --output json | jq -r '.data[]|select(."display-name"=="hermes-vcn")|.id' | head -1)
if [ -z "$VCN" ] || [ "$VCN" = "null" ]; then
  VCN=$(oci network vcn create -c "$C" --cidr-block 10.0.0.0/16 --display-name "${PREFIX}-vcn" --dns-label "${PREFIX}vcn" --wait-for-state AVAILABLE --output json | jq -r .data.id)
fi
echo "[*] VCN=$VCN"

IGW=$(oci network internet-gateway list -c "$C" --vcn-id "$VCN" --output json | jq -r '.data[0].id')
if [ -z "$IGW" ] || [ "$IGW" = "null" ]; then
  IGW=$(oci network internet-gateway create -c "$C" --vcn-id "$VCN" --is-enabled true --display-name "${PREFIX}-igw" --wait-for-state AVAILABLE --output json | jq -r .data.id)
fi
echo "[*] IGW=$IGW"

RT=$(oci network route-table list -c "$C" --vcn-id "$VCN" --output json | jq -r '.data[0].id')
printf '[{"destination":"0.0.0.0/0","networkEntityId":"%s"}]' "$IGW" > /tmp/route.json
oci network route-table update --rt-id "$RT" --route-rules file:///tmp/route.json --force >/dev/null

SL=$(oci network security-list list -c "$C" --vcn-id "$VCN" --output json | jq -r '.data[0].id')
cat > /tmp/ingress.json <<'EOJ'
[{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},{"source":"10.0.0.0/16","protocol":"all"}]
EOJ
echo '[{"destination":"0.0.0.0/0","protocol":"all"}]' > /tmp/egress.json
oci network security-list update --security-list-id "$SL" --ingress-security-rules file:///tmp/ingress.json --egress-security-rules file:///tmp/egress.json --force >/dev/null

SUBNET=$(oci network subnet list -c "$C" --vcn-id "$VCN" --output json | jq -r '.data[]|select(."display-name"=="farm-subnet")|.id' | head -1)
if [ -z "$SUBNET" ] || [ "$SUBNET" = "null" ]; then
  SUBNET=$(oci network subnet create -c "$C" --vcn-id "$VCN" --cidr-block 10.0.1.0/24 --display-name farm-subnet --dns-label farmsub --route-table-id "$RT" --security-list-ids "[\"$SL\"]" --wait-for-state AVAILABLE --output json | jq -r .data.id)
fi
echo "[*] SUBNET=$SUBNET"

IMG=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex --output json | jq -r '[.data[]|select(."display-name"|test("24.04"))|select(."display-name"|test("aarch64"))][0].id')
if [ -z "$IMG" ] || [ "$IMG" = "null" ]; then
  IMG=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex --output json | jq -r '.data[0].id')
fi
echo "[*] IMAGE=$IMG"

UD=$(base64 -w0 /tmp/ci.yaml)
jq -n --arg k "$SSH_PUBKEY" --arg u "$UD" '{ssh_authorized_keys:$k, user_data:$u}' > /tmp/meta.json

# ---------------- launch (retry on capacity) ----------------
INST=""
for i in $(seq 1 240); do
  if oci compute instance launch -c "$C" --availability-domain "$AD" --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMGB}" \
      --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
      --display-name "${PREFIX}-server" --metadata file:///tmp/meta.json \
      --wait-for-state RUNNING --output json > /tmp/inst.json 2>/tmp/err; then
    INST=$(jq -r .data.id /tmp/inst.json); break
  fi
  echo "[attempt $i] $(grep -io 'Out of host capacity\|LimitExceeded\|InternalError\|InvalidParameter' /tmp/err | head -1)"
  sleep 20
done
if [ -z "$INST" ]; then echo "[!] launch failed:"; tail -20 /tmp/err; exit 1; fi

IP=$(oci compute instance list-vnics --instance-id "$INST" --output json | jq -r '.data[0]."public-ip"')
echo
echo "================ DEPLOYED ================"
echo "Server public IP : $IP"
echo "SSH              : ssh -i <your oci_farm key> ubuntu@$IP"
echo "Bootstrap runs   : ~3-5 min on first boot"
echo "Next             : bash /opt/farm/farm.sh start 8"
echo "========================================="
