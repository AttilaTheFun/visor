# What the scripts in tools/ share. Sourced, not run:
#   . "$(dirname "$0")/lib.sh"

# The builder's Apple team id, from .bazelrc.user at the repository's root
# (tools/signing); the script stops when there is none.
visor_team() {
  local root team
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  team="$(sed -n 's/.*VISOR_TEAM_ID=\([A-Z0-9]*\).*/\1/p' "$root/.bazelrc.user" 2>/dev/null | head -1)"
  [ -n "$team" ] || { echo "No VISOR_TEAM_ID in .bazelrc.user (tools/signing)" >&2; return 1; }
  echo "$team"
}

# Runs one `security` command that takes a keychain's password, the password
# read from a file and passed on standard input: an argument would show in
# the process list for as long as the command runs.
#   visor_keychain create-keychain|unlock-keychain <password file> <keychain>
visor_keychain() {
  local command="$1" passfile="$2" keychain="$3"
  printf '%s -p "%s" "%s"\n' "$command" "$(cat "$passfile")" "$keychain" | security -i >/dev/null
}

# Runs xcodebuild with everything it says kept in a log, the lines that
# matter shown, and its failure said rather than swallowed. Returns
# xcodebuild's own status, so the caller decides whether to go on.
#   visor_xcodebuild <log file> <egrep pattern of lines to show> <xcodebuild arguments…>
visor_xcodebuild() {
  local log="$1" show="$2" status=0
  shift 2
  xcodebuild "$@" >"$log" 2>&1 || status=$?
  grep -E "$show" "$log" || true
  if [ "$status" -ne 0 ]; then
    echo "xcodebuild failed ($status); the whole log is at $log" >&2
  fi
  return "$status"
}
