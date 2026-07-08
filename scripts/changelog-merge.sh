#!/usr/bin/env bash
# Fold changelog.d/ fragments into CHANGELOG.md's Unreleased section.
#
#   scripts/changelog-merge.sh
#
# Each changelog.d/<slug>.md fragment is tagged on its first line
# (feature: / improvement: / fix: — see changelog.d/README.md). Bullets are
# appended to the END of the matching "### ..." section under
# "## Unreleased", preserving everything already there. Missing sections
# are created in canonical order (New Features, Improvements, Bug Fixes)
# before "### Contributors"; a missing "## Unreleased" block is created
# above the newest release heading. Merged fragments are deleted;
# changelog.d/README.md is never touched.
#
# Fails loudly on unknown tags or malformed fragments — a silently dropped
# changelog entry is worse than a broken merge.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

changelog="CHANGELOG.md"
fragments_dir="changelog.d"

[ -f "$changelog" ] || { echo "changelog-merge: $changelog not found" >&2; exit 1; }
[ -d "$fragments_dir" ] || { echo "changelog-merge: $fragments_dir/ not found" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
: > "$tmp_dir/features"
: > "$tmp_dir/improvements"
: > "$tmp_dir/fixes"

section_file_for_tag() {
  case "$1" in
    feature) echo "$tmp_dir/features" ;;
    improvement) echo "$tmp_dir/improvements" ;;
    fix) echo "$tmp_dir/fixes" ;;
    *) return 1 ;;
  esac
}

merged_fragments=()
for fragment in "$fragments_dir"/*.md; do
  [ -e "$fragment" ] || continue
  [ "$(basename "$fragment")" = "README.md" ] && continue

  first_line=""
  rest_started=false
  out=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$first_line" ] && ! $rest_started; then
      [ -z "$line" ] && continue
      first_line="$line"
      continue
    fi
    rest_started=true
    [ -z "$line" ] && continue
    case "$line" in
      "- "*|" "*|$'\t'*) out="$out$line"$'\n' ;;
      *) out="$out- $line"$'\n' ;;
    esac
  done < "$fragment"

  tag="${first_line%%:*}"
  body="${first_line#*:}"
  body="${body# }"
  section_file="$(section_file_for_tag "$tag")" || {
    echo "changelog-merge: $fragment: unknown tag '${tag}:' (expected feature:, improvement:, or fix:)" >&2
    exit 1
  }
  if [ "$first_line" = "$tag" ] || [ -z "$body" ]; then
    echo "changelog-merge: $fragment: first line must be '<tag>: <bullet text>'" >&2
    exit 1
  fi
  case "$body" in
    "- "*) printf '%s\n' "$body" >> "$section_file" ;;
    *) printf -- '- %s\n' "$body" >> "$section_file" ;;
  esac
  [ -n "$out" ] && printf '%s' "$out" >> "$section_file"
  merged_fragments+=("$fragment")
done

if [ "${#merged_fragments[@]}" -eq 0 ]; then
  echo "changelog-merge: no fragments to merge"
  exit 0
fi

awk -v features_file="$tmp_dir/features" \
    -v improvements_file="$tmp_dir/improvements" \
    -v fixes_file="$tmp_dir/fixes" '
function load(file,   line, out) {
  out = ""
  while ((getline line < file) > 0) out = out line "\n"
  close(file)
  return out
}
function emit_pending_blanks(   i) {
  for (i = 0; i < blanks; i++) print ""
  blanks = 0
}
# Append the current section pending bullets at the end of its existing
# content (held blank lines are emitted afterwards, so spacing before the
# next heading is preserved).
function close_section() {
  if (cur != "" && pending[cur] != "") {
    printf "%s", pending[cur]
    pending[cur] = ""
  }
  cur = ""
}
# Emit any sections that had no heading yet, in canonical order.
function emit_missing_sections(   i, name) {
  for (i = 1; i <= 3; i++) {
    name = order[i]
    if (pending[name] != "") {
      print "### " name
      print ""
      printf "%s", pending[name]
      print ""
      pending[name] = ""
    }
  }
}
BEGIN {
  pending["New Features"] = load(features_file)
  pending["Improvements"] = load(improvements_file)
  pending["Bug Fixes"] = load(fixes_file)
  order[1] = "New Features"; order[2] = "Improvements"; order[3] = "Bug Fixes"
  in_unreleased = 0
  seen_unreleased = 0
  cur = ""
  blanks = 0
}
/^## /  {
  if (in_unreleased) {
    close_section()
    emit_pending_blanks()
    emit_missing_sections()
    in_unreleased = 0
  } else if (!seen_unreleased && $0 != "## Unreleased") {
    # No Unreleased block exists; create one above the newest release.
    emit_pending_blanks()
    print "## Unreleased"
    print ""
    emit_missing_sections()
    seen_unreleased = 1
  } else {
    emit_pending_blanks()
  }
  if ($0 == "## Unreleased") { in_unreleased = 1; seen_unreleased = 1 }
  print
  next
}
/^### / {
  if (in_unreleased) {
    close_section()
    emit_pending_blanks()
    if ($0 == "### Contributors") emit_missing_sections()
    sub(/^### /, "")
    if ($0 in pending) cur = $0
    print "### " $0
    next
  }
  emit_pending_blanks()
  print
  next
}
/^[[:space:]]*$/ { blanks++; next }
{
  emit_pending_blanks()
  print
  next
}
END {
  if (in_unreleased) {
    close_section()
    emit_missing_sections()
  } else if (!seen_unreleased) {
    emit_pending_blanks()
    print "## Unreleased"
    print ""
    emit_missing_sections()
    blanks = 0
  }
  emit_pending_blanks()
}
' "$changelog" > "$tmp_dir/changelog.new" || { echo "changelog-merge: awk pass failed" >&2; exit 1; }

mv "$tmp_dir/changelog.new" "$changelog"
rm -f "${merged_fragments[@]}"
echo "changelog-merge: merged ${#merged_fragments[@]} fragment(s) into $changelog"
for fragment in "${merged_fragments[@]}"; do
  echo "  - $fragment"
done
