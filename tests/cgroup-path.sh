#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/piston-cgroup-path.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

source "${ROOT}/api/src/cgroup.sh"

cat > "${TEMP_DIR}/private" <<'EOF'
0::/
EOF
private="$(piston_cgroup_base "${TEMP_DIR}/private" /sys/fs/cgroup)"
[[ "$private" == /sys/fs/cgroup ]]

cat > "${TEMP_DIR}/containerd" <<'EOF'
0::/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod123.slice/cri-containerd-456.scope
EOF
containerd="$(piston_cgroup_base "${TEMP_DIR}/containerd" /sys/fs/cgroup)"
[[ "$containerd" == /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod123.slice/cri-containerd-456.scope ]]

cat > "${TEMP_DIR}/hybrid" <<'EOF'
2:cpu:/
1:name=systemd:/
EOF
if piston_cgroup_base "${TEMP_DIR}/hybrid" /sys/fs/cgroup >/dev/null 2>&1; then
  echo "accepted cgroup input without a unified hierarchy" >&2
  exit 1
fi

cat > "${TEMP_DIR}/relative" <<'EOF'
0::kubepods.slice/container.scope
EOF
if piston_cgroup_base "${TEMP_DIR}/relative" /sys/fs/cgroup >/dev/null 2>&1; then
  echo "accepted a relative cgroup v2 path" >&2
  exit 1
fi

cat > "${TEMP_DIR}/traversal" <<'EOF'
0::/kubepods.slice/../../system.slice
EOF
if piston_cgroup_base "${TEMP_DIR}/traversal" /sys/fs/cgroup >/dev/null 2>&1; then
  echo "accepted cgroup path traversal" >&2
  exit 1
fi

cat > "${TEMP_DIR}/duplicate" <<'EOF'
0::/
0::/other
EOF
if piston_cgroup_base "${TEMP_DIR}/duplicate" /sys/fs/cgroup >/dev/null 2>&1; then
  echo "accepted duplicate unified cgroup entries" >&2
  exit 1
fi

bash -n \
  "${ROOT}/api/src/cgroup.sh" \
  "${ROOT}/api/src/docker-entrypoint.sh" \
  "${ROOT}/tests/cgroup-path.sh"

echo "Piston cgroup path validation passed."
