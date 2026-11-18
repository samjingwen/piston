#!/bin/bash

piston_cgroup_base() {
  local proc_file="$1"
  local cgroup_fs="$2"
  local relative

  if ! relative="$(
    awk -F: '
      $1 == "0" && $2 == "" {
        if (found) {
          exit 2
        }
        found = 1
        print $3
      }
      END {
        if (!found) {
          exit 1
        }
      }
    ' "$proc_file"
  )"; then
    echo "Cannot identify exactly one unified cgroup path" >&2
    return 1
  fi
  case "$relative" in
    /*) ;;
    *)
      echo "Invalid cgroup v2 path: $relative" >&2
      return 1
      ;;
  esac
  if [ "$relative" != "/" ]; then
    case "$relative" in
      *//*|*/./*|*/../*|*/.|*/..)
        echo "Unsafe cgroup v2 path: $relative" >&2
        return 1
        ;;
    esac
  fi

  if [ "$relative" = "/" ]; then
    printf '%s\n' "$cgroup_fs"
  else
    printf '%s%s\n' "${cgroup_fs%/}" "$relative"
  fi
}
