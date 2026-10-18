#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "envcheck: $SRC not present, skipped"; exit 0; }

strip() { sed 's/^[[:space:]]*//'; }
dllpath_line=$(grep 'export WINEDLLPATH=' "$SRC" | grep 'x86_64-windows' | strip)
overrides_line=$(grep 'export WINEDLLOVERRIDES=' "$SRC" | grep 'lsteamclient=b' | strip)
[ -n "$dllpath_line" ] || { echo "FAIL: WINEDLLPATH merge not found"; exit 1; }
[ -n "$overrides_line" ] || { echo "FAIL: WINEDLLOVERRIDES merge not found"; exit 1; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "== WINEDLLPATH (first match wins, runner first) =="
CX_ROOT=/R
wine_unix=/R/lib/wine/x86_64-unix
WINEDLLPATH=""
eval "$dllpath_line"
is "no user value" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix" "$WINEDLLPATH"
WINEDLLPATH="/user/dir"
eval "$dllpath_line"
is "user value last" "/R/lib/wine/x86_64-windows:/R/lib/wine/x86_64-unix:/user/dir" "$WINEDLLPATH"

echo "== WINEDLLOVERRIDES (last wins, trio last) =="
WINEDLLOVERRIDES=""
eval "$overrides_line"
is "no user value" "steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="winhttp=n,b"
eval "$overrides_line"
is "user value first" "winhttp=n,b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
WINEDLLOVERRIDES="lsteamclient=n"
eval "$overrides_line"
is "trio outranks user" "lsteamclient=n;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides="vcruntime140_1=n,b;"
WINEDLLOVERRIDES="vcruntime140_1=b"
eval "$overrides_line"
is "user outranks the native runtime" \
  "vcruntime140_1=n,b;vcruntime140_1=b;steamclient=n;steamclient64=n;lsteamclient=b" "$WINEDLLOVERRIDES"
vc_overrides=""

echo "== Microsoft's Visual C++ runtime loads when it is installed =="
vc_fn=$(sed -n '/^native_vc_runtime() {/,/^}/p' "$SRC")
[ -n "$vc_fn" ] || { echo "FAIL: native_vc_runtime not found"; exit 1; }
eval "$vc_fn"
vc_work=$(mktemp -d)
WINEPREFIX="$vc_work/pfx"
sys32="$WINEPREFIX/drive_c/windows/system32"
mkdir -p "$sys32"
pe() { printf 'MZ%062d%s' 0 "$2" > "$sys32/$1.dll"; }
is "empty prefix overrides nothing" "" "$(native_vc_runtime)"
pe vcruntime140 "Wine builtin DLL"
pe msvcp140_2 "Wine builtin DLL"
is "Wine's own copies are left alone" "" "$(native_vc_runtime)"
pe msvcp140_2 "This program cannot be run in DOS mode."
pe vcruntime140_1 "This program cannot be run in DOS mode."
: > "$sys32/msvcp140.dll"
is "Microsoft's copies load first" "msvcp140=n,b;msvcp140_2=n,b;vcruntime140_1=n,b;" "$(native_vc_runtime)"
rm -rf "$vc_work"

echo "== Apple GPTK initialization and launcher environment =="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
np_support="$work/Application Support/notproton"
np_build="test"
library="$np_support/runners/crossover-$np_build/CrossOver/lib64/apple_gptk/external/libd3dshared.dylib"
init=$(sed -n '/^CX_ROOT=/,/^wine_unix=/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
[ -n "$init" ] && [ -n "$forward" ] || { echo "FAIL: runner environment blocks not found"; exit 1; }
unset CX_APPLEGPTK_LIBD3DSHARED_PATH
eval "$init"
is "runner without the library leaves the path unset" "" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
mkdir -p "$(dirname "$library")"
: > "$library"
eval "$init"
is "bundled library is selected" "$library" "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}"
is "helpers inherit the library path" "$library" "$(sh -c 'printf %s "$CX_APPLEGPTK_LIBD3DSHARED_PATH"')"
set --
eval "$forward"
forwarded=""
for arg in "$@"; do
  case "$arg" in CX_APPLEGPTK_LIBD3DSHARED_PATH=*) forwarded=${arg#*=} ;; esac
done
is "game launcher receives the path as one argument" "$library" "$forwarded"
# macOS sed stops at the first invalid UTF-8 value.
# shellcheck disable=SC2016 # The stub and loop expand inside the child shell.
after_bad=$(env -i PATH="$PATH" LANG=en_US.UTF-8 DXVK_HUD=1 sh -c '
  env() { printf "A_BAD=a\377b\nDXVK_HUD=1\n"; }
  f=$1; set --; eval "$f"; printf "%s " "$@"' sh "$forward")
is "settings after a non-UTF-8 value are forwarded" "--env DXVK_HUD=1 " "$after_bad"

echo "== Rosetta-only settings on arm64 Wine =="
drop=$(sed -n '/^np_dropped=""$/,/^fi$/p' "$SRC")
[ -n "$drop" ] || { echo "FAIL: the arm64 settings block was not found"; exit 1; }
drop_at=$(grep -n '^np_dropped=""$' "$SRC" | cut -d: -f1)
# shellcheck disable=SC2016 # Match the literal launcher loop.
forward_at=$(grep -n '^for name in $(env ' "$SRC" | cut -d: -f1)
[ "$drop_at" -lt "$forward_at" ] ||
  bad "the arm64 settings block runs before the forwarding loop" "< $forward_at" "$drop_at"
seen() { sh -c 'env | sed -nE "s/^(CX_GRAPHICS_BACKEND|D3DM_[A-Z0-9_]*|DXMT_[A-Z0-9_]*|ROSETTA_[A-Z0-9_]*)=.*/\1/p" | sort | tr "\n" " "'; }
for name in $(seen); do unset -v "$name"; done
CX_ROOT="/R R"
set_all() { export CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1 ROSETTA_ADVERTISE_AVX=0 DXMT_CONFIG=x; }
set_all
wine_unix="/R R/lib/wine/x86_64-unix"
eval "$drop"
is "x86_64 Wine keeps every setting" \
  "CX_GRAPHICS_BACKEND D3DM_ENABLE_METALFX DXMT_CONFIG ROSETTA_ADVERTISE_AVX " "$(seen)"
is "x86_64 Wine logs nothing" "" "$np_dropped"
wine_unix="/R R/lib/wine/aarch64-unix"
eval "$drop"
is "D3DMetal and Rosetta settings leave the environment" "DXMT_CONFIG " "$(seen)"
is "the run log names what was ignored" \
  "CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX" "$np_dropped"
set_all
export CX_GRAPHICS_BACKEND=dxmt
unset -v D3DM_ENABLE_METALFX ROSETTA_ADVERTISE_AVX
eval "$drop"
is "other backends stay" "CX_GRAPHICS_BACKEND DXMT_CONFIG " "$(seen)"
is "nothing to ignore logs nothing" "" "$np_dropped"
unset -v CX_GRAPHICS_BACKEND DXMT_CONFIG

echo "== Wine user name (stock Wine reads USER, CrossOver patches its own) =="
stock=$(sed -n '/^np_stock_wine=""$/,/^fi$/p' "$SRC")
tmpl_fn=$(sed -n '/^in_template_env() {/,/^}/p' "$SRC")
# shellcheck disable=SC2016 # Match the literal line.
stock_fwd=$(grep '^\[ -z "\$np_stock_wine" \]' "$SRC")
[ -n "$stock" ] && [ -n "$tmpl_fn" ] && [ -n "$stock_fwd" ] ||
  { echo "FAIL: the stock Wine user blocks were not found"; exit 1; }
user_work=$(mktemp -d)
mkdir -p "$user_work/stock/lib/wine" "$user_work/cx/lib/wine" "$user_work/cx/bin"
: > "$user_work/cx/bin/cxbottle"
# Prints the user in the process, the template env and the launcher arguments.
probe() (
  CX_ROOT="$1"; CX_HOME=h; WINELOADER=l; WINESERVER=s; wine_unix=u
  USER=macuser; export USER
  eval "$stock"
  eval "$tmpl_fn"
  # shellcheck disable=SC2329 # called by in_template_env, which is eval'd above
  without_lock_fds() { "$@"; }
  set --
  eval "$stock_fwd"
  fwd=""
  for arg in "$@"; do case "$arg" in USER=*) fwd="$fwd$arg " ;; esac; done
  printf 'process=%s template=%s forwarded=%s' "$USER" \
    "$(in_template_env /p /usr/bin/env | sed -n 's/^USER=//p')" "$fwd"
)
is "a stock Wine runs as steamuser everywhere" \
  "process=steamuser template=steamuser forwarded=USER=steamuser " "$(probe "$user_work/stock")"
is "a CrossOver runner keeps the user and adds nothing" \
  "process=macuser template=macuser forwarded=" "$(probe "$user_work/cx")"
rm -rf "$user_work"

echo "== DirectX 11 layer (DXVK, stock Wine only) =="
dxvk_fn=$(sed -n '/^install_dxvk() {/,/^}/p' "$SRC")
dxvk_place_fn=$(sed -n '/^dxvk_place() {/,/^}/p' "$SRC")
[ -n "$dxvk_fn" ] && [ -n "$dxvk_place_fn" ] ||
  { echo "FAIL: install_dxvk and dxvk_place were not found"; exit 1; }
dxvk_work=$(mktemp -d)
dxvk_layer="$dxvk_work/support/dxvk/dxvk-macOS-async-v1.10.3-20230507-repack"
for f in x64/d3d11.dll x64/d3d10core.dll x32/d3d11.dll x32/d3d10core.dll; do
  mkdir -p "$dxvk_layer/${f%/*}"
  printf 'layer %s' "$f" > "$dxvk_layer/$f"
done
# Runs install_dxvk against one prefix. Prints the return code, the override it set, and the
# number of alerts it showed. support is the directory holding dxvk/, stock is np_stock_wine.
dxvk_probe() (
  np_support="$1"; WINEPREFIX="$2"; np_stock_wine="$3"; log=/dev/null
  alerts=0
  # shellcheck disable=SC2329 # called by install_dxvk, which is eval'd below
  show_alert() { alerts=$((alerts + 1)); }
  eval "$dxvk_place_fn"
  eval "$dxvk_fn"
  rc=0; install_dxvk || rc=$?
  printf 'rc=%s overrides=%s alerts=%s' "$rc" "$np_dxvk_overrides" "$alerts"
)
same() { cmp -s "$1" "$2" && printf same || printf different; }

pfx="$dxvk_work/stock"
mkdir -p "$pfx/drive_c/windows/system32" "$pfx/drive_c/windows/syswow64"
is "a stock prefix gets the override and no alert" \
  "rc=0 overrides=d3d11,d3d10core=n,b; alerts=0" "$(dxvk_probe "$dxvk_work/support" "$pfx" 1)"
is "the x64 DLLs match the layer" "same same" \
  "$(same "$dxvk_layer/x64/d3d11.dll" "$pfx/drive_c/windows/system32/d3d11.dll") $(same "$dxvk_layer/x64/d3d10core.dll" "$pfx/drive_c/windows/system32/d3d10core.dll")"
is "the x32 DLLs match the layer" "same same" \
  "$(same "$dxvk_layer/x32/d3d11.dll" "$pfx/drive_c/windows/syswow64/d3d11.dll") $(same "$dxvk_layer/x32/d3d10core.dll" "$pfx/drive_c/windows/syswow64/d3d10core.dll")"

cx="$dxvk_work/crossover"
mkdir -p "$cx/drive_c/windows/system32"
is "a CrossOver run is untouched" "rc=0 overrides= alerts=0" "$(dxvk_probe "$dxvk_work/support" "$cx" "")"
is "a CrossOver run copies nothing" "absent" \
  "$([ -e "$cx/drive_c/windows/system32/d3d11.dll" ] && printf present || printf absent)"

is "a missing layer alerts once and continues" "rc=0 overrides= alerts=1" \
  "$(dxvk_probe "$dxvk_work/none" "$pfx" 1)"

nosw="$dxvk_work/no-syswow64"
mkdir -p "$nosw/drive_c/windows/system32"
is "no syswow64 skips the x32 files but keeps the override" "rc=0 overrides=d3d11,d3d10core=n,b; alerts=0" \
  "$(dxvk_probe "$dxvk_work/support" "$nosw" 1)"
is "no syswow64 is not created" "absent" \
  "$([ -e "$nosw/drive_c/windows/syswow64" ] && printf present || printf absent)"

ino1=$(stat -f %i "$pfx/drive_c/windows/system32/d3d11.dll")
is "a second run leaves matching files alone" "rc=0 overrides=d3d11,d3d10core=n,b; alerts=0" \
  "$(dxvk_probe "$dxvk_work/support" "$pfx" 1)"
is "the matching file keeps its inode" "$ino1" "$(stat -f %i "$pfx/drive_c/windows/system32/d3d11.dll")"

ro="$dxvk_work/read-only"
mkdir -p "$ro/drive_c/windows/system32"
chmod 555 "$ro/drive_c/windows/system32"
is "an unwritable prefix fails and leaves no temporary file" "rc=1 overrides= alerts=0" \
  "$(dxvk_probe "$dxvk_work/support" "$ro" 1)"
is "no truncated DLL or temporary file is left" "absent absent" \
  "$([ -e "$ro/drive_c/windows/system32/d3d11.dll" ] && printf present || printf absent) $([ -e "$ro/drive_c/windows/system32/d3d11.dll.notproton-tmp" ] && printf present || printf absent)"
chmod 755 "$ro/drive_c/windows/system32"
rm -rf "$dxvk_work"

if [ "$fails" -eq 0 ]; then
	echo "==> envcheck: all assertions hold"
else
	echo "==> envcheck: $fails failed"
	exit 1
fi
