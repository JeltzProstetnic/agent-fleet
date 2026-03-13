#!/usr/bin/env bash
# afd-lib.sh — Agent Fleet Daemon bash integration
# Source this file in hooks/scripts to push tasks to AFD.
#
# Environment:
#   AFD_URL   — server URL (set to your AFD instance URL)
#   AFD_TOKEN — bearer token for auth (required)
#
# Usage:
#   source afd-lib.sh
#   afd_push "wsl:my-task" "Description of the task"
#   afd_push "wsl:my-task" "Description" "in_progress"
#   afd_complete "wsl:my-task"

AFD_URL="${AFD_URL:-}"

afd_push() {
  local task_id="${1:-}"
  local description="${2:-}"
  local status="${3:-pending}"

  if [[ -z "$task_id" ]]; then
    echo "afd_push: task_id required" >&2
    return 1
  fi

  if [[ -z "${AFD_TOKEN:-}" ]]; then
    echo "afd_push: AFD_TOKEN not set" >&2
    return 1
  fi

  [[ -z "$AFD_URL" ]] && return 1

  curl -s -f -X POST "${AFD_URL}/api/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AFD_TOKEN}" \
    -d "{\"id\":\"${task_id}\",\"description\":\"${description}\",\"status\":\"${status}\"}" \
    >/dev/null 2>&1
}

afd_notify() {
  local machine="${1:-}"
  local message="${2:-}"
  local priority="${3:-normal}"
  local type="${4:-info}"

  if [[ -z "$machine" || -z "$message" ]]; then
    echo "afd_notify: machine and message required" >&2
    return 1
  fi

  if [[ -z "${AFD_TOKEN:-}" ]]; then
    echo "afd_notify: AFD_TOKEN not set" >&2
    return 1
  fi

  [[ -z "$AFD_URL" ]] && return 1

  curl -s -f -X POST "${AFD_URL}/api/notify" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AFD_TOKEN}" \
    -d "{\"machine\":\"${machine}\",\"message\":\"${message}\",\"priority\":\"${priority}\",\"type\":\"${type}\"}" \
    >/dev/null 2>&1
}

afd_complete() {
  local task_id="${1:-}"

  if [[ -z "$task_id" ]]; then
    echo "afd_complete: task_id required" >&2
    return 1
  fi

  if [[ -z "${AFD_TOKEN:-}" ]]; then
    echo "afd_complete: AFD_TOKEN not set" >&2
    return 1
  fi

  [[ -z "$AFD_URL" ]] && return 1

  curl -s -f -X PATCH "${AFD_URL}/api/tasks/${task_id}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AFD_TOKEN}" \
    -d '{"status":"completed"}' \
    >/dev/null 2>&1
}

# --- Lock functions ---

afd_lock_acquire() {
  local project="${1:-}"
  local machine="${2:-$(hostname)}"
  local session_id="${3:-$$}"
  local pid="${4:-$$}"

  if [[ -z "$project" ]]; then
    echo "afd_lock_acquire: project required" >&2
    return 1
  fi

  if [[ -z "${AFD_TOKEN:-}" ]]; then
    echo "afd_lock_acquire: AFD_TOKEN not set" >&2
    return 1
  fi

  [[ -z "$AFD_URL" ]] && return 1

  local response
  local http_code
  response=$(curl -s -w "\n%{http_code}" -X POST "${AFD_URL}/api/locks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AFD_TOKEN}" \
    -d "{\"project\":\"${project}\",\"machine\":\"${machine}\",\"sessionId\":\"${session_id}\",\"pid\":${pid}}")
  http_code=$(echo "$response" | tail -1)
  if [[ "$http_code" == "201" ]]; then
    return 0
  elif [[ "$http_code" == "409" ]]; then
    echo "afd_lock_acquire: project already locked" >&2
    return 1
  else
    echo "afd_lock_acquire: failed (HTTP $http_code)" >&2
    return 1
  fi
}

afd_lock_release() {
  local project="${1:-}"

  if [[ -z "$project" ]]; then
    echo "afd_lock_release: project required" >&2
    return 1
  fi

  if [[ -z "${AFD_TOKEN:-}" ]]; then
    echo "afd_lock_release: AFD_TOKEN not set" >&2
    return 1
  fi

  [[ -z "$AFD_URL" ]] && return 1

  curl -s -f -X DELETE "${AFD_URL}/api/locks/${project}" \
    -H "Authorization: Bearer ${AFD_TOKEN}" \
    >/dev/null 2>&1
}

afd_lock_status() {
  local project="${1:-}"

  if [[ -z "${AFD_TOKEN:-}" ]]; then
    echo "afd_lock_status: AFD_TOKEN not set" >&2
    return 1
  fi

  [[ -z "$AFD_URL" ]] && return 1

  if [[ -n "$project" ]]; then
    curl -s -f -X GET "${AFD_URL}/api/locks/${project}" \
      -H "Authorization: Bearer ${AFD_TOKEN}" \
      2>/dev/null
  else
    curl -s -f -X GET "${AFD_URL}/api/locks" \
      -H "Authorization: Bearer ${AFD_TOKEN}" \
      2>/dev/null
  fi
}

afd_lock_heartbeat() {
  local project="${1:-}"

  if [[ -z "$project" ]]; then
    echo "afd_lock_heartbeat: project required" >&2
    return 1
  fi

  if [[ -z "${AFD_TOKEN:-}" ]]; then
    echo "afd_lock_heartbeat: AFD_TOKEN not set" >&2
    return 1
  fi

  [[ -z "$AFD_URL" ]] && return 1

  curl -s -f -X PATCH "${AFD_URL}/api/locks/${project}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AFD_TOKEN}" \
    -d '{"heartbeat":true}' \
    >/dev/null 2>&1
}
