#!/usr/bin/env bash
# Claudex State Helpers
#
# Source this from other scripts:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh"
#
# Provides:
#   claudex_new_review_id            -- generates YYYYMMDD-HHMMSS-XXXXXX
#   claudex_validate_review_id <id>  -- returns 0 if valid format, else 1
#   claudex_state_write <file> <s>   -- atomic write (tmp + rename)
#   claudex_state_read_field <f> <k> -- read a YAML field from a state file
#   claudex_phase_transition <f> <from> <to> -- CAS phase transition
#   claudex_lock_write <file>        -- writes current PID
#   claudex_lock_is_active <file>    -- returns 0 if PID alive, else 1
#   claudex_sweep_stale              -- removes loops older than threshold
#   claudex_find_active_loop         -- prints path of most-recent state file
#
# All functions are safe to call -- they never throw. They return non-zero on
# failure so the caller can decide how to handle it.

CLAUDEX_STATE_DIR="${CLAUDEX_STATE_DIR:-.claude/claudex}"
CLAUDEX_STALE_MINUTES="${CLAUDEX_STALE_MINUTES:-15}"

claudex_new_review_id() {
  local ts
  ts=$(date -u +%Y%m%d-%H%M%S 2>/dev/null) || return 1
  local suffix
  suffix=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 6) || suffix="abc123"
  printf '%s-%s' "$ts" "$suffix"
}

claudex_validate_review_id() {
  local id="$1"
  [ -n "$id" ] || return 1
  echo "$id" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'
}

claudex_state_write() {
  local file="$1"
  local content="$2"
  [ -n "$file" ] || return 1
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  local tmp="${file}.tmp.$$"
  printf '%s' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

claudex_state_read_field() {
  local file="$1"
  local field="$2"
  [ -f "$file" ] || return 1
  grep -E "^${field}:" "$file" 2>/dev/null | head -1 | sed -E "s/^${field}: *//"
}

claudex_phase_transition() {
  local file="$1"
  local from_phase="$2"
  local to_phase="$3"
  [ -f "$file" ] || return 1
  local current
  current=$(claudex_state_read_field "$file" "phase")
  if [ "$current" != "$from_phase" ]; then
    return 1
  fi
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp="${file}.tmp.$$"
  sed -E -e "s/^phase: .*/phase: ${to_phase}/" \
         -e "s/^last_updated_at: .*/last_updated_at: ${now}/" \
         "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

claudex_state_set_field() {
  local file="$1"
  local field="$2"
  local value="$3"
  [ -f "$file" ] || return 1
  local tmp="${file}.tmp.$$"
  if grep -qE "^${field}:" "$file" 2>/dev/null; then
    sed -E "s/^${field}: .*/${field}: ${value}/" "$file" > "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; return 1; }
  else
    cat "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    printf '%s: %s\n' "$field" "$value" >> "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

claudex_lock_write() {
  local lock_file="$1"
  [ -n "$lock_file" ] || return 1
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 1
  echo "$$" > "$lock_file" 2>/dev/null || return 1
  return 0
}

claudex_lock_is_active() {
  local lock_file="$1"
  [ -f "$lock_file" ] || return 1
  local pid
  pid=$(cat "$lock_file" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

claudex_sweep_stale() {
  [ -d "$CLAUDEX_STATE_DIR" ] || return 0
  # Find state files older than threshold; remove their state, lock, runner,
  # prompt, and per-review findings dir.
  find "$CLAUDEX_STATE_DIR" -maxdepth 1 -type f -name "*.state" -mmin "+$CLAUDEX_STALE_MINUTES" 2>/dev/null \
  | while read -r f; do
    local id
    id=$(basename "$f" .state)
    rm -f "$f" "$CLAUDEX_STATE_DIR/${id}.lock" "$CLAUDEX_STATE_DIR/${id}-runner.sh" "$CLAUDEX_STATE_DIR/${id}-prompt.txt" 2>/dev/null
    rm -rf "$CLAUDEX_STATE_DIR/${id}" 2>/dev/null
  done
  return 0
}

claudex_find_active_loop() {
  [ -d "$CLAUDEX_STATE_DIR" ] || return 1
  local latest
  latest=$(ls -t "$CLAUDEX_STATE_DIR"/*.state 2>/dev/null | head -1)
  [ -n "$latest" ] || return 1
  printf '%s' "$latest"
}

claudex_count_active_loops() {
  [ -d "$CLAUDEX_STATE_DIR" ] || { echo 0; return 0; }
  ls "$CLAUDEX_STATE_DIR"/*.state 2>/dev/null | wc -l | tr -d ' '
}

# claudex_findings_severity_counts <findings_file>
# Prints "high=N medium=N low=N" by counting bullet lines under each ## header.
# A bullet line is a line that begins with "- " inside that section. Sections
# are delimited by the next "## " header or EOF. If the file is missing or
# unreadable, prints "high=0 medium=0 low=0" so callers can always parse.
claudex_findings_severity_counts() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "high=0 medium=0 low=0"
    return 0
  fi
  awk '
    BEGIN { sec=""; h=0; m=0; l=0 }
    /^## High/         { sec="h"; next }
    /^## Medium/       { sec="m"; next }
    /^## Low/          { sec="l"; next }
    /^## /             { sec="";  next }
    /^- / {
      if      (sec=="h") h++
      else if (sec=="m") m++
      else if (sec=="l") l++
    }
    END { printf "high=%d medium=%d low=%d\n", h, m, l }
  ' "$file" 2>/dev/null || echo "high=0 medium=0 low=0"
}
