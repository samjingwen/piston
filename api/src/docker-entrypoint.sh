#!/bin/bash

set -euo pipefail

CGROUP_FS="/sys/fs/cgroup"
source /piston_api/src/cgroup.sh

if [ ! -e "$CGROUP_FS" ]; then
  echo "Cannot find $CGROUP_FS. Please make sure your system is using cgroup v2"
  exit 1
fi

if [ -e "$CGROUP_FS/unified" ]; then
  echo "Combined cgroup v1+v2 mode is not supported. Please make sure your system is using pure cgroup v2"
  exit 1
fi

if [ ! -e "$CGROUP_FS/cgroup.subtree_control" ]; then
  echo "Cgroup v2 not found. Please make sure cgroup v2 is enabled on your system"
  exit 1
fi

CGROUP_BASE="$(piston_cgroup_base /proc/self/cgroup "$CGROUP_FS")"
if [ ! -d "$CGROUP_BASE" ]; then
  echo "Cannot find the process cgroup $CGROUP_BASE"
  exit 1
fi

install -d -m 0700 /run/isolate
printf '%s\n' "${CGROUP_BASE%/}/isolate" > /run/isolate/cgroup-root
chmod 0600 /run/isolate/cgroup-root

cd "$CGROUP_BASE" && \
mkdir isolate/ && \
echo 1 > isolate/cgroup.procs && \
echo '+cpuset +cpu +io +memory +pids' > cgroup.subtree_control && \
cd isolate && \
mkdir init && \
echo 1 > init/cgroup.procs && \
echo '+cpuset +memory' > cgroup.subtree_control && \
echo "Initialized cgroup" && \
chown -R piston:piston /piston && \
ulimit -n 65536 && \
exec node /piston_api/src/sandbox-supervisor.js
