#!/usr/bin/env bash
# Interaction drive pass: launch each showcase app on Linux under Xvfb and
# run a representative scenario (clicks, text input, wheel scrolling, window
# resize incl. minimum-size clamp), screenshotting at defined points.
# Results land in /out/drive/<app>/: drive.log (ok:/MISS:/WARN: lines),
# engine *.png screenshots, final snapshot, and the app's stderr log.
#
# Run recon.sh first (it builds the apps); this script only launches.
set -u
source /src/tools/linux-truth/lib.sh

OUT=/out/drive
mkdir -p "$OUT"
start_xvfb

# window_bounds — echo the current @w1 bounds string, e.g. "0,0 320x490".
window_bounds() {
  snapshot_lines | sed -n 's/.*window @w1 "[^"]*" bounds=(\([^)]*\)).*/\1/p' | head -1
}

# set_text <canvas> <role> <name> <text> — focus + replace through the
# real input-event path (select-all + text_input).
set_text() {
  local id
  id=$(widget_id "$1" "$2" "$3")
  [ -n "$id" ] || { echo "WARN: widget $2 \"$3\" not found for set-text"; return 1; }
  send widget-action "$1" "$id" set-text "$4"
}

# wheel <canvas> <role> <name> <delta-y> — scroll at a widget's position.
wheel() {
  local id
  id=$(widget_id "$1" "$2" "$3")
  [ -n "$id" ] || { echo "WARN: widget $2 \"$3\" not found for wheel"; return 1; }
  send widget-wheel "$1" "$id" "$4"
}

# check_min_size — ask for an absurdly small window and report the clamp.
check_min_size() {
  send resize 50 50
  sleep 1
  echo "bounds after resize 50x50 request: $(window_bounds)"
}

finish() {
  local out="$1" canvas="$2"
  sleep 0.5
  snapshot_lines > "$out/final-snapshot.txt"
  echo "final: $(grep -o 'dispatch_errors=[0-9]*' "$out/final-snapshot.txt" | head -1)"
  grep -icE "error|critical|warning|assert" /tmp/app.log >/dev/null 2>&1 \
    && echo "app log flagged lines: $(grep -icE 'error|critical|warning|assert' /tmp/app.log)" \
    || echo "app log flagged lines: 0"
  grep -iE "error|critical|warning|assert" /tmp/app.log | head -10 > "$out/log-flags.txt" 2>/dev/null
  cp /tmp/app.log "$out/app.log" 2>/dev/null
  stop_app
}

drive_calculator() {
  local out="$OUT/calculator" c=calc-canvas
  cd /work/examples/calculator && launch_app zig-out/bin/calculator || return 1
  click $c button "All clear"; click $c button 7; click $c button Multiply
  click $c button 8; click $c button Equals
  expect 'name="56"'
  shot $c "$out/1-compute.png"
  # Keyboard path: digits and enter through widget-key on the keypad.
  id=$(widget_id $c textbox "Expression")
  send widget-action $c "$id" focus
  send widget-key $c 1 1; send widget-key $c 2 2; send widget-key $c plus +
  send widget-key $c 3 3; send widget-key $c equal =
  expect 'name="15"' 5000 || echo "note: keyboard entry path did not produce 15"
  shot $c "$out/2-keyboard.png"
  echo "bounds before resize: $(window_bounds)"
  send resize 420 640; sleep 1
  echo "bounds after resize 420x640: $(window_bounds)"
  check_min_size
  shot $c "$out/3-resized.png"
  finish "$out" $c
}

drive_notes() {
  local out="$OUT/notes" c=notes-canvas
  cd /work/examples/notes && launch_app zig-out/bin/notes || return 1
  shot $c "$out/1-initial.png"
  # Notes persists its store across launches (app-dirs state), so assert
  # the count DELTA rather than an absolute count.
  count_before=$(snapshot_lines | grep -oE '[0-9]+ notes' | head -1 | grep -oE '[0-9]+')
  click $c button "New note"
  expect "$((count_before + 1)) notes" 5000
  id=$(widget_id $c textbox "Note editor")
  send widget-action $c "$id" focus
  set_text $c textbox "Note editor" "Linux-live-truth"
  expect 'Linux-live-truth' 5000
  shot $c "$out/2-typed.png"
  set_text $c textbox "Search notes" "Piranesi"
  expect '1 shown' 5000
  shot $c "$out/3-search.png"
  set_text $c textbox "Search notes" ""
  wheel $c button "New folder" 40
  send resize 900 600; sleep 1
  echo "bounds after resize 900x600: $(window_bounds)"
  check_min_size
  shot $c "$out/4-resized.png"
  finish "$out" $c
}

drive_soundboard() {
  local out="$OUT/soundboard" c=soundboard-canvas
  cd /work/examples/soundboard && launch_app zig-out/bin/soundboard || return 1
  shot $c "$out/1-initial.png"
  click $c tab "Songs"
  selected=no
  for _ in $(seq 1 50); do
    snapshot_lines | grep -oE 'role=tab name="Songs"[^|]*' | grep -qE 'state=\[[a-z,]*selected' \
      && { selected=yes; break; }
    sleep 0.1
  done
  [ "$selected" = yes ] && echo "ok: Songs tab selected" || echo "MISS: Songs tab not selected"
  shot $c "$out/2-songs.png"
  click $c button "Play or pause"
  sleep 1
  shot $c "$out/3-playing.png"
  set_text $c textbox "Search library" "glass"
  sleep 1
  shot $c "$out/4-search.png"
  wheel $c tab "Albums" -40
  send resize 1200 800; sleep 1
  echo "bounds after resize 1200x800: $(window_bounds)"
  check_min_size
  finish "$out" $c
}

drive_markdown_viewer() {
  local out="$OUT/markdown-viewer" c=viewer-canvas
  cd /work/examples/markdown-viewer && launch_app zig-out/bin/markdown-viewer || return 1
  shot $c "$out/1-initial.png"
  id=$(widget_id $c textbox "Markdown source")
  send widget-action $c "$id" focus
  send widget-key $c end
  # Real typing into the source pane; the preview should keep up.
  send widget-key $c z
  sleep 1
  shot $c "$out/2-typed.png"
  # Scroll the preview pane.
  wheel $c link "https://github.com" 60
  sleep 1
  shot $c "$out/3-scrolled.png"
  send resize 1400 800; sleep 1
  echo "bounds after resize 1400x800: $(window_bounds)"
  check_min_size
  finish "$out" $c
}

drive_system_monitor() {
  local out="$OUT/system-monitor" c=monitor-canvas
  cd /work/examples/system-monitor && launch_app zig-out/bin/system-monitor || return 1
  sleep 3
  shot $c "$out/1-initial.png"
  click $c button "Sort by Memory"
  sleep 1
  shot $c "$out/2-sort-memory.png"
  set_text $c textbox "Filter processes" "zig"
  sleep 1
  shot $c "$out/3-filter.png"
  click $c button "Pause or resume sampling"
  sleep 1
  # Settings opens a second window; the snapshot should grow a @w2.
  click $c button "Open settings window"
  sleep 2
  snapshot_lines | grep -q 'window @w2' && echo "ok: settings window @w2 appeared" \
    || echo "MISS: settings window @w2"
  snapshot_lines | grep -o 'window @w2 "[^"]*"' | head -1
  xshot "$out/4-two-windows-x11.png"
  send resize 1300 800; sleep 1
  echo "bounds after resize 1300x800: $(window_bounds)"
  check_min_size
  finish "$out" $c
}

drive_gpu_dashboard() {
  local out="$OUT/gpu-dashboard" c=dashboard-canvas
  cd /work/examples/gpu-dashboard && launch_app zig-out/bin/gpu-dashboard || return 1
  expect 'gpu_nonblank=true' 15000
  shot $c "$out/1-initial.png"
  id=$(widget_id $c switch "Auto refresh")
  send widget-click $c "$id"
  expect 'Auto refresh off.' 10000
  set_text $c textbox "Segment search" "native-engine"
  sleep 1
  id=$(widget_id $c slider "Confidence threshold")
  send widget-action $c "$id" increment
  sleep 1
  shot $c "$out/2-interacted.png"
  send resize 1120 700; sleep 1
  echo "bounds after resize 1120x700: $(window_bounds)"
  snapshot_lines | grep -q 'view @w1/dashboard-canvas kind=gpu_surface.*bounds=(0,0 1120x700)' \
    && echo "ok: canvas relayout 1120x700" || echo "MISS: canvas relayout after resize"
  check_min_size
  shot $c "$out/3-resized.png"
  finish "$out" $c
}

drive_deck() {
  local out="$OUT/deck" c=deck-canvas
  cd /work/examples/deck && launch_app zig-out/bin/deck || return 1
  shot $c "$out/1-initial.png"
  click $c button "Play or pause"
  sleep 1
  shot $c "$out/2-playing.png"
  id=$(widget_id $c slider "Volume")
  send widget-action $c "$id" decrement
  # Playlist opens a second window.
  click $c button "Playlist window"
  sleep 2
  snapshot_lines | grep -q 'window @w2' && echo "ok: playlist window @w2 appeared" \
    || echo "MISS: playlist window @w2"
  xshot "$out/3-two-windows-x11.png"
  check_min_size
  finish "$out" $c
}

drive_feed() {
  local out="$OUT/feed" c=feed-canvas
  cd /work/examples/feed && launch_app zig-out/bin/feed || return 1
  shot $c "$out/1-initial.png"
  click $c button "Like post 0"
  sleep 0.5
  shot $c "$out/2-liked.png"
  # Windowed list scroll: wheel down hard, the visible post range must move.
  before=$(snapshot_lines | grep -o 'posts [0-9]*–[0-9]*' | head -1)
  wheel $c button "Like post 3" 400
  sleep 1
  wheel $c button "Like post 6" 400 2>/dev/null || true
  sleep 1
  after=$(snapshot_lines | grep -o 'posts [0-9]*–[0-9]*' | head -1)
  echo "scroll: '$before' -> '$after'"
  [ "$before" != "$after" ] && echo "ok: windowed scroll moved" || echo "MISS: scroll did not move visible range"
  shot $c "$out/3-scrolled.png"
  send resize 700 900; sleep 1
  echo "bounds after resize 700x900: $(window_bounds)"
  check_min_size
  finish "$out" $c
}

drive_kanban() {
  local out="$OUT/kanban" c=kanban-canvas
  cd /work/examples/kanban && launch_app zig-out/bin/kanban || return 1
  shot $c "$out/1-initial.png"
  click $c button "Add card"
  expect '3 todo' 5000
  # Move the first card right.
  id=$(snapshot_lines | grep -o 'widget @w1/kanban-canvas#[0-9]* role=button name=">"' | head -1 | grep -o '#[0-9]*' | tr -d '#')
  [ -n "$id" ] && send widget-click $c "$id"
  expect '2 doing' 5000
  shot $c "$out/2-moved.png"
  send resize 1100 700; sleep 1
  echo "bounds after resize 1100x700: $(window_bounds)"
  check_min_size
  finish "$out" $c
}

drive_ui_inbox() {
  local out="$OUT/ui-inbox" c=inbox-canvas
  cd /work/examples/ui-inbox && launch_app zig-out/bin/ui-inbox || return 1
  shot $c "$out/1-initial.png"
  id=$(snapshot_lines | grep -o 'widget @w1/inbox-canvas#[0-9]* role=textbox name=""' | head -1 | grep -o '#[0-9]*' | tr -d '#')
  send widget-action $c "$id" set-text "verify-linux-truth"
  click $c button "Add task"
  expect '4 open' 5000
  # Complete the first task via its checkbox, then filter to done.
  id=$(snapshot_lines | grep -o 'widget @w1/inbox-canvas#[0-9]* role=checkbox name=""' | head -1 | grep -o '#[0-9]*' | tr -d '#')
  [ -n "$id" ] && send widget-click $c "$id"
  expect '1 done' 5000
  click $c tab "done"
  sleep 0.5
  shot $c "$out/2-done-filter.png"
  click $c button "Clear done"
  expect '0 done' 5000
  send resize 900 700; sleep 1
  echo "bounds after resize 900x700: $(window_bounds)"
  check_min_size
  shot $c "$out/3-resized.png"
  finish "$out" $c
}

APPS="${APPS:-calculator notes soundboard markdown-viewer system-monitor gpu-dashboard deck feed kanban ui-inbox}"
for app in $APPS; do
  echo "==== drive $app ===="
  mkdir -p "$OUT/$app"
  fn="drive_$(echo "$app" | tr '-' '_')"
  "$fn" > >(tee "$OUT/$app/drive.log") 2>&1
done
echo "drive complete"
