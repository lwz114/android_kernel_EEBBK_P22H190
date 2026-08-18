#!/usr/bin/env bash
set -euo pipefail

# Repack A3 socko.img by collecting every built kernel module into out_a3/socko,
# then writing those modules into the image with the SELinux xattr expected by
# stock/vendor init when loading modules.

STOCK_SOCKO="${1:-/mnt/c/Users/rtyus/Desktop/socko.img}"
KERNEL_ROOT="${2:-$HOME/android_kernel_EEBBK_P21H180}"
SOCKO_DIR="${3:-$KERNEL_ROOT/out_a3/socko}"
OUT_DIR="${4:-/mnt/c/Users/rtyus/Documents/New project/socko_repack_autolabel_$(date +%Y%m%d_%H%M%S)}"
OUT_NAME="${5:-socko_autolabel.img}"
SELABEL="${6:-u:object_r:vendor_file:s0}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

need debugfs
need e2fsck
need find
need realpath
need sort

if [[ ! -f "$STOCK_SOCKO" ]]; then
  echo "stock socko image not found: $STOCK_SOCKO" >&2
  exit 1
fi

if [[ ! -d "$KERNEL_ROOT" ]]; then
  echo "kernel root not found: $KERNEL_ROOT" >&2
  exit 1
fi

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd -P)"
if [[ "$SOCKO_DIR" != /* ]]; then
  SOCKO_DIR="$KERNEL_ROOT/$SOCKO_DIR"
fi
mkdir -p "$SOCKO_DIR"
SOCKO_DIR="$(cd "$SOCKO_DIR" && pwd -P)"
mkdir -p "$OUT_DIR"
OUT_IMG="$OUT_DIR/$OUT_NAME"
CMD_FILE="$OUT_DIR/debugfs_replace.cmds"
VERIFY_FILE="$OUT_DIR/xattrs.txt"
FILES_FILE="$OUT_DIR/files.txt"
FSCK_FILE="$OUT_DIR/e2fsck.txt"
SHA_FILE="$OUT_DIR/sha256.txt"
FOUND_FILE="$OUT_DIR/found_modules.txt"
COPIED_FILE="$OUT_DIR/copied_modules.tsv"
WORK_DIR="$(mktemp -d /tmp/a3_socko_repack_selinux.XXXXXX)"
SELABEL_FILE="$WORK_DIR/selabel.bin"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cp -f "$STOCK_SOCKO" "$OUT_IMG"
printf '%s\0' "$SELABEL" > "$SELABEL_FILE"
: > "$CMD_FILE"
: > "$VERIFY_FILE"
: > "$FOUND_FILE"
: > "$COPIED_FILE"

socko_rel="$(realpath --relative-to="$KERNEL_ROOT" "$SOCKO_DIR" 2>/dev/null || true)"
find_args=(. -type f -name '*.ko')
if [[ -n "$socko_rel" && "$socko_rel" != ..* && "$socko_rel" != "." ]]; then
  find_args+=(! -path "./${socko_rel#./}/*")
fi

pushd "$KERNEL_ROOT" >/dev/null
mapfile -d '' found_modules < <(find "${find_args[@]}" -print0 | sort -z)
popd >/dev/null

if [[ "${#found_modules[@]}" -eq 0 ]]; then
  echo "no .ko modules were found under $KERNEL_ROOT" >&2
  exit 1
fi

find "$SOCKO_DIR" -maxdepth 1 -type f -name '*.ko' -delete

declare -A copied_basenames=()
duplicates=0
for rel in "${found_modules[@]}"; do
  src="$KERNEL_ROOT/${rel#./}"
  dst="$(basename "$rel")"

  if [[ -n "${copied_basenames[$dst]:-}" ]]; then
    echo "WARN duplicate module basename: $dst; using $rel over ${copied_basenames[$dst]}" >&2
    duplicates=$((duplicates + 1))
  fi

  copied_basenames[$dst]="$rel"
  cp -f "$src" "$SOCKO_DIR/$dst"
  printf '%s\n' "$rel" >> "$FOUND_FILE"
  printf '%s\t%s\n' "$rel" "$dst" >> "$COPIED_FILE"
done

mapfile -d '' socko_modules < <(find "$SOCKO_DIR" -maxdepth 1 -type f -name '*.ko' -print0 | sort -z)
if [[ "${#socko_modules[@]}" -eq 0 ]]; then
  echo "no .ko modules were staged into $SOCKO_DIR" >&2
  exit 1
fi

for src in "${socko_modules[@]}"; do
  dst="$(basename "$src")"
  {
    printf 'rm /%s\n' "$dst"
    printf 'write %s /%s\n' "$src" "$dst"
    printf 'ea_set -f %s /%s security.selinux\n' "$SELABEL_FILE" "$dst"
  } >> "$CMD_FILE"
done

debugfs -w -f "$CMD_FILE" "$OUT_IMG" > "$OUT_DIR/debugfs.log" 2>&1
if grep -Eq 'Usage:|while .* extended attribute|Could not allocate|Permission denied' "$OUT_DIR/debugfs.log"; then
  echo "debugfs reported an error while replacing modules; see $OUT_DIR/debugfs.log" >&2
  exit 1
fi

e2fsck -fy "$OUT_IMG" > "$FSCK_FILE" 2>&1
debugfs -R 'ls -p /' "$OUT_IMG" > "$FILES_FILE" 2>&1

missing_xattr=0
for src in "${socko_modules[@]}"; do
  dst="$(basename "$src")"
  xattr_output="$(debugfs -R "ea_list /$dst" "$OUT_IMG" 2>&1 || true)"
  {
    printf '%s: ' "$dst"
    printf '%s' "$xattr_output" | sed -n '/Extended attributes:/,$p' | tr '\n' ' '
    printf '\n'
  } >> "$VERIFY_FILE"

  if ! printf '%s' "$xattr_output" | grep -q 'security.selinux'; then
    missing_xattr=$((missing_xattr + 1))
  fi
done

if [[ "$missing_xattr" -ne 0 ]]; then
  echo "SELinux xattr verification failed; see $VERIFY_FILE" >&2
  exit 1
fi

sha256sum "$OUT_IMG" > "$SHA_FILE"

echo "socko repacked: $OUT_IMG"
echo "module search root: $KERNEL_ROOT"
echo "staged socko dir: $SOCKO_DIR"
echo "modules found: ${#found_modules[@]}"
echo "modules staged/written: ${#socko_modules[@]}"
echo "duplicate basenames overwritten: $duplicates"
echo "selinux label: $SELABEL"
echo "copied modules: $COPIED_FILE"
echo "verify xattrs: $VERIFY_FILE"
