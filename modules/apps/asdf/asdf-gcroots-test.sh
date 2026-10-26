#!/usr/bin/env bash
# Test of asdf-gcroots.sh: a fake ASDF_DATA_DIR and a stub nix-store first on
# PATH (it "realises" by creating the root symlink, or fails for paths listed
# in STUB_UNREALISABLE). Needs bash, grep, findutils and coreutils.
# Usage: asdf-gcroots-test.sh [path to asdf-gcroots.sh] (default: the sibling
# script). Also a flake check, asdf-gcroots-check.nix.
# shellcheck disable=SC2015  # `A && ok || fail`: ok never fails
set -euo pipefail

script="$(realpath "${1:-$(dirname "${BASH_SOURCE[0]}")/asdf-gcroots.sh}")"
root="$(realpath "$(mktemp -d)")"
trap 'rm -rf "$root"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

stubs="$root/stubs"
mkdir -p "$stubs"
# The shebang is the running bash: the Nix build sandbox has no /usr/bin/env
{ printf '#!%s\n' "$BASH"; cat; } > "$stubs/nix-store" <<'STUB'
# args: --realise --add-root <root> --indirect <path>
if [[ "${STUB_UNREALISABLE:-}" == *"${5##*/}"* ]]; then exit 1; fi
ln -sfn "$5" "$3"
STUB
chmod +x "$stubs/nix-store"
# grep/find stub: fails (exit 2, like a read error) when an argument names
# STUB_SCAN_FAIL, otherwise runs the real tool
for t in grep find; do
  real="$(command -v "$t")"
  { printf '#!%s\n' "$BASH"; printf 'real=%q\n' "$real"; cat; } > "$stubs/$t" <<'STUB'
for arg in "$@"; do
  if [[ -n "${STUB_SCAN_FAIL:-}" && "$arg" == *"$STUB_SCAN_FAIL"* ]]; then echo "stub scan failure" >&2; exit 2; fi
done
exec "$real" "$@"
STUB
  chmod +x "$stubs/$t"
done
# The script runs under the unit's PATH: the stubs plus the bin dirs of exactly
# the runtimeInputs (no sh). ASDF_TEST_PATH_DIRS (colon-separated, set by the
# flake check) names them; otherwise a dir of symlinks to the real tools.
if [[ -n "${ASDF_TEST_PATH_DIRS:-}" ]]; then
  tools_path="$ASDF_TEST_PATH_DIRS"
else
  mkdir -p "$root/tools"
  for tool in grep find xargs sort mktemp rm mkdir basename dirname cat head ln; do
    ln -s "$(command -v "$tool")" "$root/tools/$tool"
  done
  tools_path="$root/tools"
fi
unit_path="$stubs:$tools_path"

a=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-glibc-2.40
b=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-openssl-3.0
c=/nix/store/cccccccccccccccccccccccccccccc00-zlib-1.3

export ASDF_DATA_DIR="$root/data" ASDF_GCROOTS_DIR="$root/roots"
inst="$ASDF_DATA_DIR/installs/python/3.13.7"
reset() {
  rm -rf "$ASDF_DATA_DIR" "$ASDF_GCROOTS_DIR"
  mkdir -p "$inst/lib/python3.13" "$inst/lib/python3.13/config-3.13"
  printf 'x\0%s\0y' "$a" > "$inst/lib/libfoo.so.1"
  printf 'CC=%s/bin/gcc\n' "$b" > "$inst/lib/python3.13/config-3.13/Makefile"
  printf "libdir = '%s/lib'\n" "$a" > "$inst/lib/python3.13/_sysconfigdata__linux.py"
  echo plain > "$inst/README"
}
run() { PATH="$unit_path" "$BASH" "$script" "$@" > "$root/out" 2> "$root/err"; }

# refs found (also in non-ELF files) and rooted
reset
run || fail "run exited $?"
[[ -L "$ASDF_GCROOTS_DIR/python-3.13.7/${a##*/}" && -L "$ASDF_GCROOTS_DIR/python-3.13.7/${b##*/}" ]] \
  && ok "refs rooted" || fail "refs not rooted: $(ls "$ASDF_GCROOTS_DIR/python-3.13.7" 2>&1)"
run --list
[[ "$(sort "$root/out")" == "python 3.13.7 $a
python 3.13.7 $b" ]] && ok "--list output" || fail "--list: $(cat "$root/out")"

# stale root removed
ln -s "$c" "$ASDF_GCROOTS_DIR/python-3.13.7/${c##*/}"
run
[[ ! -e "$ASDF_GCROOTS_DIR/python-3.13.7/${c##*/}" && -L "$ASDF_GCROOTS_DIR/python-3.13.7/${a##*/}" ]] \
  && ok "stale root removed" || fail "stale root kept"

# uninstalled version's roots removed
mkdir -p "$ASDF_GCROOTS_DIR/python-3.9.0"
ln -s "$c" "$ASDF_GCROOTS_DIR/python-3.9.0/${c##*/}"
run
[[ ! -e "$ASDF_GCROOTS_DIR/python-3.9.0" && -d "$ASDF_GCROOTS_DIR/python-3.13.7" ]] \
  && ok "uninstalled version's roots removed" || fail "uninstalled version's roots kept"

# unrealisable path: warning, exit 0
STUB_UNREALISABLE="${b##*/}" run && rc=0 || rc=$?
[[ $rc == 0 ]] && grep -q "$b" "$root/err" && ok "unrealisable warns, exit 0" \
  || fail "unrealisable: rc=$rc err=$(cat "$root/err")"

# a file name with a newline holding a store path is rooted (S02)
reset
printf 'x%s\n' "$c" > "$inst/lib/odd
name.txt"
run || fail "newline run exited $?"
[[ -L "$ASDF_GCROOTS_DIR/python-3.13.7/${c##*/}" ]] \
  && ok "newline file name rooted" || fail "newline file name not rooted"

# several plugins and versions at once, --list covers all (C03)
reset
mkdir -p "$ASDF_DATA_DIR/installs/python/3.12.1" "$ASDF_DATA_DIR/installs/ruby/3.3.0"
echo "$c" > "$ASDF_DATA_DIR/installs/python/3.12.1/f"
echo "$b" > "$ASDF_DATA_DIR/installs/ruby/3.3.0/f"
run --list
[[ "$(sort "$root/out")" == "python 3.12.1 $c
python 3.13.7 $a
python 3.13.7 $b
ruby 3.3.0 $b" ]] && ok "--list several installs" || fail "--list several: $(cat "$root/out")"
run
[[ -L "$ASDF_GCROOTS_DIR/python-3.12.1/${c##*/}" && -L "$ASDF_GCROOTS_DIR/ruby-3.3.0/${b##*/}" \
  && -L "$ASDF_GCROOTS_DIR/python-3.13.7/${a##*/}" ]] \
  && ok "several installs rooted" || fail "several installs not rooted"

# --list without an installs dir: exit 0, no output, no "keeping" line (C03)
rm -rf "$ASDF_DATA_DIR/installs"
run --list && rc=0 || rc=$?
[[ $rc == 0 && ! -s "$root/out" ]] && ! grep -q keeping "$root/err" \
  && ok "--list without installs dir" || fail "--list no dir: rc=$rc out=$(cat "$root/out") err=$(cat "$root/err")"

# no installs dir: every root kept
reset
run
rm -rf "$ASDF_DATA_DIR/installs"
run && rc=0 || rc=$?
[[ $rc == 0 && -L "$ASDF_GCROOTS_DIR/python-3.13.7/${a##*/}" ]] \
  && ok "no installs dir keeps roots" || fail "no installs dir: rc=$rc"

# empty installs dir: every root kept too (C01)
mkdir -p "$ASDF_DATA_DIR/installs"
run && rc=0 || rc=$?
[[ $rc == 0 && -L "$ASDF_GCROOTS_DIR/python-3.13.7/${a##*/}" ]] && grep -q keeping "$root/err" \
  && ok "empty installs dir keeps roots" || fail "empty installs dir: rc=$rc"

# scan error in one install: its roots are kept (even stale), others pruned (C02)
reset
mkdir -p "$ASDF_DATA_DIR/installs/python/9.9.9"
echo "$c" > "$ASDF_DATA_DIR/installs/python/9.9.9/f"
run
ln -s "$b" "$ASDF_GCROOTS_DIR/python-9.9.9/${b##*/}"
ln -s "$c" "$ASDF_GCROOTS_DIR/python-3.13.7/${c##*/}"
STUB_SCAN_FAIL=/python/9.9.9 run && rc=0 || rc=$?
[[ -L "$ASDF_GCROOTS_DIR/python-9.9.9/${b##*/}" && -L "$ASDF_GCROOTS_DIR/python-9.9.9/${c##*/}" ]] \
  && grep -q 'read errors' "$root/err" && ok "scan error keeps that install's roots" \
  || fail "scan error: rc=$rc err=$(cat "$root/err")"
[[ ! -e "$ASDF_GCROOTS_DIR/python-3.13.7/${c##*/}" ]] \
  && ok "other install still pruned" || fail "other install not pruned"

# every install unreadable: loud failure, roots kept (not pruned)
reset
run
ln -s "$c" "$ASDF_GCROOTS_DIR/python-3.13.7/${c##*/}"
STUB_SCAN_FAIL=/python/3.13.7 run && rc=0 || rc=$?
[[ $rc != 0 && -L "$ASDF_GCROOTS_DIR/python-3.13.7/${c##*/}" ]] && grep -q 'read errors' "$root/err" \
  && ok "all installs unreadable exits non-zero" || fail "all unreadable: rc=$rc err=$(cat "$root/err")"
grep -q 'stub scan failure' "$root/err" && ok "first read error logged" || fail "no read error detail: $(cat "$root/err")"

if (( failures )); then echo "$failures failure(s)" >&2; exit 1; fi
echo "all ok"
