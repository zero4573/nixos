# Keep the nix store paths that asdf-built tools link against alive.
#
# asdf compiles pythons (and friends) from source against nix store deps
# (glibc, openssl, zlib, ...); nothing roots those paths, so `nix-collect-
# garbage` deletes them and the tool stops working. This scans the files
# under $ASDF_DATA_DIR/installs/<plugin>/<version>/ for /nix/store/<hash>-<name>
# references, realises each (refetching GC'd ones from the substituter) and
# registers it as an indirect GC root under $ASDF_GCROOTS_DIR/<plugin>-<version>/.
# Roots of versions that are no longer installed are removed.
#
# usage: asdf-gcroots [--list]
#   --list  print "<plugin> <version> <store path>" for every reference and
#           change nothing (no realise, no roots)
set -euo pipefail

list_only=0
case "${1:-}" in
  --list) list_only=1 ;;
  "") ;;
  *) echo "usage: asdf-gcroots [--list]" >&2; exit 2 ;;
esac

data_dir="${ASDF_DATA_DIR:-$HOME/.asdf}"
roots_dir="${ASDF_GCROOTS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/asdf-gcroots}"

# Runs grep over the NUL-separated names in file $1 in batches of 500 (no sh:
# the unit's PATH has none, and xargs can't tell grep's "no match" (1) from a
# real error (2) in its own exit status). Output to $2, stderr to $3. Returns 1
# on a real error (grep status > 1).
grep_batches() {
  local list="$1" out="$2" errf="$3" rc=0 i
  shift 3
  local -a names
  mapfile -d '' -t names < "$list"
  : > "$out"
  for ((i = 0; i < ${#names[@]}; i += 500)); do
    grep "$@" "${names[@]:i:500}" >> "$out" 2>> "$errf" || (( $? == 1 )) || rc=1
  done
  return "$rc"
}

# Store paths referenced by the files of one install, written to $2: grep -l
# narrows to the files that mention the store at all (ELF files, but also
# _sysconfigdata_*.py and config-*/Makefile), then only those are scanned for
# the full paths. NUL-separated throughout (file names may hold newlines).
# Returns 1 when a find/grep read error happened: the list may be incomplete;
# the first error message goes to stderr.
refs_of() {
  local files hits errf rc=0
  files="$(mktemp)"; hits="$(mktemp)"; errf="$(mktemp)"
  find "$1" -type f -print0 > "$files" 2>> "$errf" || rc=1
  grep_batches "$files" "$hits" "$errf" -alFZ /nix/store/ || rc=1
  grep_batches "$hits" "$2.raw" "$errf" -aoh -E "/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+" || rc=1
  sort -u "$2.raw" > "$2" || rc=1
  rm -f "$files" "$hits" "$2.raw"
  if (( rc )); then
    echo "asdf-gcroots: first read error in $1: $(head -n 1 "$errf")" >&2
  fi
  rm -f "$errf"
  return "$rc"
}

# Without an installs dir (data dir unmounted, moved, not set up yet) nothing
# is known about what is installed: keep every root instead of pruning them
if (( ! list_only )) && [[ ! -d "$data_dir/installs" ]]; then
  echo "asdf-gcroots: $data_dir/installs is not a directory, keeping all roots" >&2
  exit 0
fi

declare -A wanted=()
unrealised=()
scanned=0 failed=0

for install in "$data_dir"/installs/*/*/; do
  [[ -d "$install" ]] || continue
  install="${install%/}"
  version="$(basename "$install")"
  plugin="$(basename "$(dirname "$install")")"
  key="$plugin-$version"
  wanted[$key]=1
  refs_file="$(mktemp)"
  scan_failed=0
  refs_of "$install" "$refs_file" || scan_failed=1
  scanned=$((scanned + 1))
  (( ! scan_failed )) || failed=$((failed + 1))
  mapfile -t refs < "$refs_file"
  rm -f "$refs_file"

  if (( list_only )); then
    for ref in "${refs[@]}"; do
      printf '%s %s %s\n' "$plugin" "$version" "$ref"
    done
    continue
  fi

  mkdir -p "$roots_dir/$key"
  declare -A keep=()
  for ref in "${refs[@]}"; do
    name="$(basename "$ref")"
    keep[$name]=1
    if ! nix-store --realise --add-root "$roots_dir/$key/$name" --indirect "$ref" > /dev/null 2>&1; then
      unrealised+=("$plugin $version: $ref")
    fi
  done
  # Roots of references the install no longer has, unless the scan was
  # incomplete (then the list can't tell what is gone)
  if (( scan_failed )); then
    echo "asdf-gcroots: read errors scanning $install, keeping its existing roots" >&2
    unset keep
    continue
  fi
  for root in "$roots_dir/$key"/*; do
    [[ -L "$root" ]] || continue
    [[ -n "${keep[$(basename "$root")]:-}" ]] || rm -f "$root"
  done
  unset keep
done

# Every install unreadable (or none readable): fail loudly, so the unit and
# nix-gc behind it notice; nothing is pruned
if (( scanned > 0 && failed == scanned )); then
  echo "asdf-gcroots: read errors in all $scanned install(s), nothing scanned" >&2
  exit 1
fi

(( list_only )) && exit 0

# An empty installs dir tells as little as a missing one: keep every root
if (( ${#wanted[@]} == 0 )); then
  echo "asdf-gcroots: no installs under $data_dir/installs, keeping all roots" >&2
  exit 0
fi

# Roots of uninstalled versions
for dir in "$roots_dir"/*/; do
  [[ -d "$dir" ]] || continue
  [[ -n "${wanted[$(basename "$dir")]:-}" ]] || rm -rf "$dir"
done

if (( ${#unrealised[@]} )); then
  echo "asdf-gcroots: ${#unrealised[@]} store path(s) can't be realised (not in any substituter):" >&2
  printf '  %s\n' "${unrealised[@]}" >&2
  echo "  fix: asdf uninstall <plugin> <version> && asdf install <plugin> <version>" >&2
fi
