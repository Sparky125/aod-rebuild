#!/usr/bin/env bash
# rewrite_png_refs.sh — point the game's consumers at the converted .webp files.
#
# Consumes the manifest written by convert_png_to_webp.gd
# (tools/webp_converted.txt: one res://assets/....png path per line) and
# rewrites ".png" -> ".webp" references in:
#     rebuild/data/*.json   rebuild/scripts/*.gd   rebuild/scenes/*.tscn
#
# Rewrite rules, in order of increasing risk:
#   1. FULL PATHS  — "res://assets/<rel>.png" for every converted file
#                    (always applied; exact string, zero ambiguity).
#   2. BARE NAMES  — "name.png" where EVERY copy of that basename under
#                    assets/ is converted (dedup safety: walk.png exists in 61
#                    unit dirs, but if all 61 are converted, every bare
#                    reference lands on a .webp, so a global rename is safe).
#                    Skipped (deferred, reported) for partial ONLY= runs where
#                    a non-converted .png with the same basename still exists.
#   3. DYNAMIC SUFFIXES — the code builds paths at runtime:
#                        "res://assets/units/%s.png" % key,
#                        HUD_ART + art + ".png", _piece(x + "_middle.png"),
#                        "res://assets/units/{type}.png" (sprite_anims.json).
#                        Only applied when the conversion covers ALL .png
#                        under assets/ (i.e. a full run), because these
#                        builders are shared across directories.
#
# Safety properties:
#   * Only rewrites references whose target .webp exists on disk (manifest
#     entries are validated; stale entries are ignored with a warning).
#   * Word-boundary-aware sed patterns (a pre-char guard, so e.g.
#     "gold_coin.png" is NOT hit by a "coin.png" rule).
#   * Idempotent: .webp references no longer match the .png patterns; a
#     second run produces an empty diff.
#   * Prints every replacement (unified diff, -U0) and mirrors it to
#     tools/webp_rewrite_log.txt. Nothing under assets/ is touched.
#
# Usage:
#   cd "Army of Darkness Rebuild" && bash rebuild/tools/rewrite_png_refs.sh
#   # (run AFTER convert_png_to_webp.gd; preview first:  --dry-run)

set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# REBUILD_DIR override exists so the sed logic can be validated against a
# throwaway copy of the tree without touching the real project.
PROJ_DIR="${REBUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ASSETS="$PROJ_DIR/assets"
MANIFEST="$PROJ_DIR/tools/webp_converted.txt"
LOG="$PROJ_DIR/tools/webp_rewrite_log.txt"

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }

[ -f "$MANIFEST" ] || { err "manifest not found: $MANIFEST — run convert_png_to_webp.gd first."; exit 1; }
[ -d "$ASSETS" ]   || { err "assets dir not found: $ASSETS"; exit 2; }

WORK="$(mktemp -d)"
# KEEPWORK=1 keeps the temp dir (sed program, backups) for debugging.
[ "${KEEPWORK:-0}" = 1 ] || trap 'rm -rf "$WORK"' EXIT
[ "${KEEPWORK:-0}" = 1 ] && note "KEEPWORK: temp dir = $WORK"
SED_PROGRAM="$WORK/rewrite.sed"
mkdir -p "$WORK/backup"

# ---------------------------------------------------------------- manifest --
# Normalized list of converted rel paths (relative to PROJ_DIR, e.g.
# assets/unit_frames/ash/walk.png) whose .webp actually exists on disk.
: > "$WORK/converted.txt"
while IFS= read -r line; do
	line="${line%$'\r'}"
	[ -z "$line" ] && continue
	rel="${line#res://}"
	case "$rel" in
		assets/*.png) ;;                       # expected shape
		*) note "SKIP (unexpected manifest line): $line"; continue ;;
	esac
	if [ -f "$PROJ_DIR/${rel%.png}.webp" ]; then
		printf '%s\n' "$rel" >> "$WORK/converted.txt"
	else
		note "SKIP (target .webp missing — stale manifest entry): $rel"
	fi
done < "$MANIFEST"
sort -u -o "$WORK/converted.txt" "$WORK/converted.txt"

N_CONV=$(wc -l < "$WORK/converted.txt" | tr -d ' ')
N_CONV=${N_CONV//[!0-9]/}
[ "${N_CONV:-0}" -gt 0 ] || { err "manifest holds no verifiable converted files. Nothing to do."; exit 3; }

# ------------------------------------------------- inventory & ambiguity ----
# Inventory of ALL .png under assets/ (any depth, including the root files).
find "$ASSETS" -type f -name '*.png' | sed "s|^$PROJ_DIR/||" | sort -u > "$WORK/inventory.txt"
N_INV=$(wc -l < "$WORK/inventory.txt" | tr -d ' ')
N_INV=${N_INV//[!0-9]/}

# A png is FULLY CONVERTED iff it is listed in converted.txt (membership
# already implies its .webp exists).
awk '
	FNR==NR { full[$0]=1; next }
	{ if ($0 in full) print }
' "$WORK/converted.txt" "$WORK/inventory.txt" > "$WORK/full_conv.txt"

# basename -> count of inventory pngs / count of fully converted pngs.
# A bare-name rewrite for basename B is SAFE iff every inventory png named B
# is fully converted (then any bare reference lands on a .webp whatever the
# loader's directory). Partial basenames are DEFERRED and reported.
awk -F/ '
	FNR==NR { full[$0]=1; next }
	{
		b=$NF
		inv[b]++
		if ($0 in full) fullc[b]++
	}
	END {
		for (b in inv) {
			fc = (b in fullc) ? fullc[b] : 0
			if (fc == inv[b]) printf "SAFE %s\n", b
			else if (fc > 0)  printf "DEFERRED %s|%d|%d\n", b, fc, inv[b]
		}
	}' "$WORK/full_conv.txt" "$WORK/inventory.txt" | sort > "$WORK/name_status.txt"

awk '$1=="SAFE"     { print $2 }' "$WORK/name_status.txt" > "$WORK/safe_names.txt"
awk '$1=="DEFERRED" { sub(/^DEFERRED /, ""); print }' "$WORK/name_status.txt" > "$WORK/deferred.txt"

N_SAFE=$(wc -l < "$WORK/safe_names.txt" | tr -d ' '); N_SAFE=${N_SAFE//[!0-9]/}
N_DEF=$(wc -l < "$WORK/deferred.txt" | tr -d ' ');   N_DEF=${N_DEF//[!0-9]/}

FULL_COVERAGE=0
[ "${N_CONV:-0}" -eq "${N_INV:-0}" ] && FULL_COVERAGE=1

note "manifest converted+verified : $N_CONV"
note ".png inventory under assets : $N_INV"
note "safe bare basenames         : $N_SAFE"
note "deferred (partial) basenames: $N_DEF"
note "full coverage (all assets)  : $([ "$FULL_COVERAGE" -eq 1 ] && echo yes || echo 'NO — dynamic-suffix rules disabled')"

# ------------------------------------------------------- build sed program --
# Escape the regex dot in literal paths. Staged asset names in this project
# are [A-Za-z0-9_.] only (no hyphens/spaces/brackets — verified), so the dot
# is the only metachar that occurs; anything else fails loudly below.
BS='\'
esc() {
	local s="$1"
	case "$s" in
		*[!A-Za-z0-9_./]*)
			note "WARN: path contains regex-special chars; esc() under-escapes it: $s"
			;;
	esac
	s="${s//./${BS}.}"
	printf '%s' "$s"
}

{
	# Rule 1 — exact full res:// paths (converted files only).
	while IFS= read -r rel; do
		webp="${rel%.png}.webp"
		printf '%s\n' "s|res://$(esc "$rel")|res://$(esc "$webp")|g" >> "$SED_PROGRAM"
	done < "$WORK/converted.txt"

	# Rule 2 — bare basenames, only when unambiguous-in-outcome.
	# The pre-char guard \([^A-Za-z0-9_.-]\) stops "coin.png" matching inside
	# "gold_coin.png" and stops partial-stem hits like "_middle.png".
	PRE='\([^A-Za-z0-9_.-]\)'
	DOT='\.'
	REF='\1'
	while IFS= read -r b; do
		name="${b%.png}"                     # basename WITHOUT extension
		eb=$(esc "$name")
		printf '%s\n' "s/${PRE}${eb}${DOT}png/${REF}${eb}.webp/g" >> "$SED_PROGRAM"
		printf '%s\n' "s/^${eb}${DOT}png/${eb}.webp/g" >> "$SED_PROGRAM"
	done < "$WORK/safe_names.txt"

	# Rule 3 — runtime path builders. Only with full coverage.
	if [ "$FULL_COVERAGE" -eq 1 ]; then
		printf '%s\n' 's|%s\.png"|%s.webp"|g' >> "$SED_PROGRAM"        # "%s.png" format strings
		printf '%s\n' 's|+ "\.png")|+ ".webp")|g' >> "$SED_PROGRAM"    # x + ".png" concat suffixes
		printf '%s\n' 's|+ "_middle\.png"|+ "_middle.webp"|g' >> "$SED_PROGRAM"
		printf '%s\n' 's|+ "_middle_alpha\.png"|+ "_middle_alpha.webp"|g' >> "$SED_PROGRAM"
		printf '%s\n' 's|{type}\.png"|{type}.webp"|g' >> "$SED_PROGRAM" # sprite_anims.json template
		# Runtime-composed filenames: wname + "_icon.png", part + "_middle.png".
		# Safe only at full coverage (then any real stem.png was already a
		# converted bare name, or the stem is composed at runtime).
		printf '%s\n' 's|+ "\([A-Za-z0-9_]*\)\.png"|+ "\1.webp"|g' >> "$SED_PROGRAM"
	fi
}

N_RULES=$(wc -l < "$SED_PROGRAM" | tr -d ' '); N_RULES=${N_RULES//[!0-9]/}

# ------------------------------------------------------------- consumers ----
CONSUMERS=()
for f in "$PROJ_DIR"/data/*.json "$PROJ_DIR"/scripts/*.gd "$PROJ_DIR"/scenes/*.tscn; do
	[ -f "$f" ] && CONSUMERS+=("$f")
done
[ "${#CONSUMERS[@]}" -gt 0 ] || { err "no consumer files found under $PROJ_DIR"; exit 4; }

note ""
note "Scanning ${#CONSUMERS[@]} consumer file(s) with ${N_RULES} sed rule(s)${DRY_RUN:+ (DRY RUN — no files written)}..."

CHANGED=0
mkdir -p "$WORK/result"          # rewritten copies (dry-run) for leftover scan
for f in "${CONSUMERS[@]}"; do
	rel_f="${f#"$PROJ_DIR"/}"
	bk="$WORK/backup/$(printf '%s' "$rel_f" | tr '/' '_')"
	res="$WORK/result/$(printf '%s' "$rel_f" | tr '/' '_')"
	cp "$f" "$bk"
	# -b: several consumer files use CRLF line endings; MSYS sed would strip
	# them without --binary, churning every line of every file.
	if [ "$DRY_RUN" -eq 1 ]; then
		sed -b -f "$SED_PROGRAM" "$f" > "$res"
		if ! cmp -s "$f" "$res"; then
			CHANGED=$((CHANGED + 1))
			note "--- would rewrite: $rel_f"
			diff -U0 "$f" "$res" | sed -b -n '3,$p' | sed -b 's|^|    |'
		fi
	else
		sed -b -i -f "$SED_PROGRAM" "$f"
		if ! cmp -s "$f" "$bk"; then
			CHANGED=$((CHANGED + 1))
			note "--- rewrote: $rel_f" | tee -a "$LOG"
			diff -U0 "$bk" "$f" | sed -b -n '3,$p' | sed -b 's|^|    |' | tee -a "$LOG"
		fi
		cp "$f" "$res"
	fi
done

# ------------------------------------------------------- report leftovers ---
# (a) any reference that still points at a CONVERTED path with .png —
# scanned against the RESULT copies (rewritten state), not the originals.
awk '{ printf "res://%s\n", $0 }' "$WORK/converted.txt" > "$WORK/conv_patterns.txt"
RESULT_FILES=()
for f in "$WORK/result"/*; do [ -f "$f" ] && RESULT_FILES+=("$f"); done
LEFTOVER=0
LEFT_HITS=$(grep -n -F -f "$WORK/conv_patterns.txt" "${RESULT_FILES[@]}" 2>/dev/null || true)
if [ -n "$LEFT_HITS" ]; then
	note ""
	note "LEFTOVER full-path references to converted files (should be none):"
	printf '%s\n' "$LEFT_HITS" | sed "s|$WORK/result/||"
	LEFTOVER=$(printf '%s\n' "$LEFT_HITS" | wc -l | tr -d ' ')
fi

# (b) deferred basenames still referenced somewhere
if [ -s "$WORK/deferred.txt" ]; then
	note ""
	note "DEFERRED bare names (some copies not converted — NOT rewritten; re-run after a full conversion):"
	while IFS='|' read -r dname fc tot; do
		hits=$(grep -l -F -- "$dname" "${CONSUMERS[@]}" 2>/dev/null | sed "s|^$PROJ_DIR/||" | tr '\n' ' ')
		[ -n "$hits" ] && note "  $dname ($fc of $tot copies converted) -> referenced in: $hits"
	done < "$WORK/deferred.txt"
fi

note ""
if [ "$DRY_RUN" -eq 1 ]; then
	note "DRY RUN complete. $CHANGED file(s) would change. Re-run without --dry-run to apply."
else
	note "Done. $CHANGED file(s) rewritten. Full diff appended to: $LOG"
	note "Verify the game, delete the converted .png files (+ their .png.import sidecars),"
	note "then re-import: godot --headless --path rebuild --import"
	[ "$LEFTOVER" -eq 0 ] || exit 5
fi
exit 0
