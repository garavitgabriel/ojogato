#!/bin/bash
# JSON helpers for the machine-readable (--json) modes. Sourced, never run.
#
# Every --json mode prints ONE JSON object on one line, so agents (the MCP server) can
# parse it without guessing. Strings are escaped here, in one place: captions carry
# newlines, emoji and the occasional quote, and a hand-rolled printf in each script is how
# a stray `"` in OJOGATO_SUBJECT would turn into a parse error on the agent's side.
# Unknown values are `null`, never omitted and never a sentinel like 9999.

# json_str <value> -> "escaped"   (\ " tab CR, and newlines become \n)
json_str() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { ORS = ""; printf "\"" }
    {
      if (NR > 1) printf "\\n"
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
      printf "%s", $0
    }
    END { printf "\"" }'
}

# json_str_or_null <value> -> "escaped" | null (empty -> null)
json_str_or_null() { if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi; }

# json_num_or_null <value> -> the number as-is | null (anything non-numeric -> null)
json_num_or_null() {
  case "$1" in
    ''|*[!0-9.-]*|*.*.*|-|.) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# json_bool <0|1|true|false|empty> -> true | false | null
json_bool() {
  case "$1" in
    1|true)  printf 'true' ;;
    0|false) printf 'false' ;;
    *)       printf 'null' ;;
  esac
}

# json_fail <exit_code> <message> — print {"error":…} on stdout and exit
json_fail() { printf '{"error":%s}\n' "$(json_str "$2")"; exit "$1"; }

# yavg_of <ffmpeg> <image|video> -> mean luma (0-255) of the brightest frame, or empty
yavg_of() {
  "$1" -v info -i "$2" -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
    -f null - 2>/dev/null | grep -o 'YAVG=[0-9.]*' | cut -d= -f2 | sort -n | tail -1
}

# is_dark <luma> -> 0 (true) when below OJOGATO_DARK_YAVG; 1 otherwise (or no luma)
is_dark() {
  [ -n "$1" ] || return 1
  awk "BEGIN{exit !($1 < ${OJOGATO_DARK_YAVG:-16})}"
}

# dark_json <luma> -> true | false | null
dark_json() {
  if [ -z "$1" ]; then printf 'null'
  elif is_dark "$1"; then printf 'true'
  else printf 'false'; fi
}
