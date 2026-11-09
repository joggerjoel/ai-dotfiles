# shellcheck shell=bash
# log-contract-v1 helper 1.0.0
# Single-file Bash helper for log contract v1 (guides/log-contract-v1.md).
# Copy this file into a project and source it; update by copying it again.
# Runs under bash 3.2 and later. Needs only date, od and tr.
#
#   . ./logv1.sh
#   logv1 info job.start "Starting import" source=dice rows=120
#   logv1 error db.lock_timeout "Lock wait timeout" table=orders err.type=MariaDB err.code=1205
#
# Arguments after the message are key=value pairs. Keys starting with err. fill
# the err object (type, code, message, stack); the rest go into fields as strings.
# Set LOGV1_PROC to override the process name and LOGV1_FD to write elsewhere
# than stderr (fd 2).

# shellcheck disable=SC2034 # read by the project that sources this file
LOGV1_VERSION="1.0.0"

_logv1_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  case $s in
    *[[:cntrl:]]*) s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\037') ;;
  esac
  printf '%s' "$s"
}

_logv1_one_line() {
  local s=$1
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  printf '%s' "$s"
}

_logv1_ts() {
  local raw
  raw=$(date +%Y-%m-%dT%H:%M:%S%z)
  printf '%s:%s' "${raw%??}" "${raw#"${raw%??}"}"
}

logv1() {
  if [ $# -lt 3 ]; then
    echo "logv1: usage: logv1 LEVEL EVENT MESSAGE [key=value ...]" >&2
    return 2
  fi
  local level=$1 event=$2 msg=$3
  shift 3
  case $level in
    debug|info|warn|error) ;;
    *) echo "logv1: unknown level '$level'" >&2; return 2 ;;
  esac
  if ! printf '%s' "$event" | grep -Eq '^[a-z0-9_]+(\.[a-z0-9_]+)*$'; then
    echo "logv1: event must look like db.lock_timeout, got '$event'" >&2
    return 2
  fi

  if [ -z "${LOGV1_RUN_ID:-}" ]; then
    LOGV1_RUN_ID=${PROCRUN_RUN_ID:-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')}
  fi
  local proc=${LOGV1_PROC:-${PROCRUN_PROC:-}}
  if [ -z "$proc" ]; then
    proc=$(basename -- "$0")
    proc=${proc%.*}
  fi

  local fields="" err="" pair key value
  for pair in "$@"; do
    case $pair in
      *=*) ;;
      *) echo "logv1: expected key=value, got '$pair'" >&2; return 2 ;;
    esac
    key=${pair%%=*}
    value=${pair#*=}
    case $key in
      err.*) err="$err${err:+,}\"$(_logv1_escape "${key#err.}")\":\"$(_logv1_escape "$value")\"" ;;
      *) fields="$fields${fields:+,}\"$(_logv1_escape "$key")\":\"$(_logv1_escape "$value")\"" ;;
    esac
  done

  local line
  line="{\"v\":1,\"ts\":\"$(_logv1_ts)\",\"level\":\"$level\",\"proc\":\"$(_logv1_escape "$proc")\""
  line="$line,\"run_id\":\"$(_logv1_escape "$LOGV1_RUN_ID")\",\"event\":\"$event\""
  line="$line,\"msg\":\"$(_logv1_escape "$(_logv1_one_line "$msg")")\""
  [ -n "$fields" ] && line="$line,\"fields\":{$fields}"
  [ -n "$err" ] && line="$line,\"err\":{$err}"
  printf '%s\n' "$line}" >&"${LOGV1_FD:-2}"
}
