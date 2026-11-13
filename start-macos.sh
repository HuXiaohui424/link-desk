#!/usr/bin/env bash
# 一键准备并启动 macOS Debug 版 RustDesk。
# 已有工具和依赖会跳过下载；每次启动都会重编，避免改了代码却还在跑旧包。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "这个脚本只用于 macOS。" >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64) VCPKG_TRIPLET="x64-osx" ;;
  arm64)  VCPKG_TRIPLET="arm64-osx" ;;
  *)
    echo "不支持的架构: $HOST_ARCH" >&2
    exit 1
    ;;
esac

CACHE_DIR="${RUSTDESK_DEV_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/rustdesk-dev}"
BIN_DIR="$CACHE_DIR/bin"
mkdir -p "$BIN_DIR"

workflow="$ROOT/.github/workflows/flutter-build.yml"
read_workflow_value() {
  local key="$1"
  awk -F'"' -v k="$key" '$0 ~ "^  " k ":" {print $2; exit}' "$workflow"
}

RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-$(read_workflow_value MAC_RUST_VERSION)}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.81}"
if [[ "$HOST_ARCH" == "arm64" ]]; then
  FLUTTER_VERSION="${FLUTTER_VERSION:-$(read_workflow_value FLUTTER_MACOS_ARM_VERSION)}"
fi
FLUTTER_VERSION="${FLUTTER_VERSION:-$(read_workflow_value FLUTTER_VERSION)}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.24.5}"
VCPKG_COMMIT="${VCPKG_COMMIT:-$(python3 -c 'import json,sys; print(json.load(open("vcpkg.json"))["vcpkg-configuration"]["default-registry"]["baseline"])' 2>/dev/null || true)}"
VCPKG_COMMIT="${VCPKG_COMMIT:-9e593bb18ea69cc5095e012465dcd675a822ed0d}"

APP_DEBUG="$ROOT/flutter/build/macos/Build/Products/Debug/RustDesk.app"
PROD_DEBUG="$ROOT/flutter/build/macos/Build/Products/Debug"

CLEAN=0
NO_RUN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --no-run) NO_RUN=1 ;;
    -h|--help)
      cat <<'EOF'
用法: ./start-macos.sh [--clean] [--no-run]

  --clean   清掉 Flutter/Xcode Debug 产物和 Rust debug 目标，再完整重编
  --no-run  只构建，不打开应用

会优先使用本机已有的 flutter、rustup、vcpkg、nasm。
没有的才会下载到 $RUSTDESK_DEV_CACHE（默认 ~/.cache/rustdesk-dev）。
每次启动都会重新编译，避免改了代码却还在跑旧包。
EOF
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

prepend_path() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

working_python() {
  local cand
  for cand in "${PYTHON3:-}" python3 /usr/bin/python3; do
    [[ -n "$cand" ]] || continue
    if "$cand" -c 'import math, json, pathlib' >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

PYTHON3="$(working_python || true)"
if [[ -z "$PYTHON3" ]]; then
  echo "需要一个能用的 python3。" >&2
  exit 1
fi

detect_flutter_sdk() {
  local flutter_bin sdk
  if have flutter; then
    flutter_bin="$(command -v flutter)"
    sdk="$(cd "$(dirname "$flutter_bin")/.." && pwd)"
    if [[ -x "$sdk/bin/flutter" ]]; then
      printf '%s\n' "$sdk"
      return 0
    fi
  fi
  if [[ -n "${FLUTTER_SDK:-}" && -x "$FLUTTER_SDK/bin/flutter" ]]; then
    printf '%s\n' "$FLUTTER_SDK"
    return 0
  fi
  if [[ -x "$CACHE_DIR/flutter/bin/flutter" ]]; then
    printf '%s\n' "$CACHE_DIR/flutter"
    return 0
  fi
  return 1
}

detect_vcpkg_root() {
  if [[ -n "${VCPKG_ROOT:-}" && -x "$VCPKG_ROOT/vcpkg" ]]; then
    printf '%s\n' "$VCPKG_ROOT"
    return 0
  fi
  if have vcpkg; then
    local bin
    bin="$(command -v vcpkg)"
    printf '%s\n' "$(cd "$(dirname "$bin")" && pwd)"
    return 0
  fi
  if [[ -x "$CACHE_DIR/vcpkg/vcpkg" ]]; then
    printf '%s\n' "$CACHE_DIR/vcpkg"
    return 0
  fi
  return 1
}

detect_llvm_home() {
  if [[ -n "${LLVM_HOME:-}" && -e "$LLVM_HOME/lib/libclang.dylib" ]]; then
    printf '%s\n' "$LLVM_HOME"
    return 0
  fi
  local brew_llvm=""
  if have brew; then
    brew_llvm="$(brew --prefix llvm 2>/dev/null || true)"
  fi
  local cand
  for cand in \
    "$brew_llvm" \
    "$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain/usr" \
    "$(xcode-select -p 2>/dev/null)/usr" \
    /Library/Developer/CommandLineTools/usr
  do
    [[ -n "$cand" ]] || continue
    if [[ -e "$cand/lib/libclang.dylib" || -x "$cand/bin/clang" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

nasm_ok() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  "$bin" --version 2>/dev/null | grep -q 'NASM version 2\.16'
}

require_xcode() {
  if ! have xcodebuild; then
    echo "未找到 xcodebuild。请安装 Xcode，并执行:" >&2
    echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
  fi
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Xcode 还不能用。请先同意许可并完成首次启动:" >&2
    echo "  sudo xcodebuild -license accept" >&2
    echo "  sudo xcodebuild -runFirstLaunch" >&2
    exit 1
  fi
}

ensure_rust() {
  if ! have rustup; then
    log "安装 rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "$RUST_TOOLCHAIN"
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
  prepend_path "$HOME/.cargo/bin"
  if ! rustup run "$RUST_TOOLCHAIN" rustc -V >/dev/null 2>&1; then
    log "安装 Rust $RUST_TOOLCHAIN"
    rustup toolchain install "$RUST_TOOLCHAIN"
  fi
  export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
}

ensure_flutter() {
  local sdk
  if sdk="$(detect_flutter_sdk)"; then
    FLUTTER_SDK="$sdk"
    prepend_path "$FLUTTER_SDK/bin"
    return
  fi
  log "下载 Flutter $FLUTTER_VERSION"
  local zip="$CACHE_DIR/flutter_macos_${FLUTTER_VERSION}-stable.zip"
  mkdir -p "$CACHE_DIR"
  if [[ ! -s "$zip" ]]; then
    curl -fL --retry 3 -o "$zip" \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_${FLUTTER_VERSION}-stable.zip"
  fi
  rm -rf "$CACHE_DIR/flutter"
  unzip -q "$zip" -d "$CACHE_DIR"
  FLUTTER_SDK="$CACHE_DIR/flutter"
  prepend_path "$FLUTTER_SDK/bin"
  flutter config --enable-macos-desktop >/dev/null
}

ensure_nasm() {
  if have nasm && nasm_ok "$(command -v nasm)"; then
    return
  fi
  if nasm_ok "$BIN_DIR/nasm"; then
    prepend_path "$BIN_DIR"
    return
  fi
  log "安装 NASM 2.16.03"
  local tmp
  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "$tmp/nasm.zip" \
    https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/macosx/nasm-2.16.03-macosx.zip
  unzip -q "$tmp/nasm.zip" -d "$tmp"
  local extracted
  extracted="$(find "$tmp" -type f -name nasm | head -n 1)"
  install -m 755 "$extracted" "$BIN_DIR/nasm"
  prepend_path "$BIN_DIR"
}

ensure_vcpkg() {
  if VCPKG_ROOT="$(detect_vcpkg_root)"; then
    export VCPKG_ROOT
  else
    log "准备 vcpkg"
    VCPKG_ROOT="$CACHE_DIR/vcpkg"
    if [[ ! -d "$VCPKG_ROOT/.git" ]]; then
      git clone https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
    fi
    git -C "$VCPKG_ROOT" fetch --quiet origin "$VCPKG_COMMIT"
    git -C "$VCPKG_ROOT" checkout --quiet "$VCPKG_COMMIT"
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
    export VCPKG_ROOT
  fi

  local installed="$VCPKG_ROOT/installed/$VCPKG_TRIPLET"
  if [[ -f "$installed/lib/libvpx.a" && -f "$installed/lib/libopus.a" && -f "$installed/lib/libaom.a" && -f "$installed/lib/libavcodec.a" ]]; then
    return
  fi
  log "安装 vcpkg 原生依赖 ($VCPKG_TRIPLET)"
  "$VCPKG_ROOT/vcpkg" install --triplet "$VCPKG_TRIPLET" --x-install-root="$VCPKG_ROOT/installed"
}

ensure_bridge() {
  local missing=0
  local f
  for f in \
    flutter/lib/generated_bridge.dart \
    flutter/macos/Runner/bridge_generated.h \
    src/bridge_generated.rs \
    src/bridge_generated.io.rs
  do
    if [[ ! -s "$ROOT/$f" ]]; then
      missing=1
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    return
  fi
  if ! have gh; then
    echo "缺少 Flutter/Rust 桥接文件，且本机没有 gh，无法从 CI 下载。" >&2
    exit 1
  fi
  local artifact="bridge-artifact"
  if [[ "$HOST_ARCH" == "arm64" ]]; then
    artifact="bridge-artifact-flutter-3.44"
  fi
  log "下载 Flutter/Rust 桥接文件 ($artifact)"
  local sha artifact_id artifact_sha local_bridge_sha archive
  sha="$(git -C "$ROOT" rev-parse HEAD)"
  artifact_id="$(gh api "repos/{owner}/{repo}/actions/artifacts?name=$artifact&per_page=100" \
    --jq ".artifacts[] | select(.expired == false and .workflow_run.head_sha == \"$sha\") | .id" | head -n 1)"

  if [[ -z "$artifact_id" ]]; then
    local_bridge_sha="$(git -C "$ROOT" hash-object src/flutter_ffi.rs)"
    while read -r artifact_id artifact_sha; do
      [[ -n "$artifact_id" && -n "$artifact_sha" ]] || continue
      if [[ "$(gh api "repos/rustdesk/rustdesk/contents/src/flutter_ffi.rs?ref=$artifact_sha" --jq '.sha' 2>/dev/null || true)" == "$local_bridge_sha" ]]; then
        break
      fi
      artifact_id=""
    done < <(gh api "repos/rustdesk/rustdesk/actions/artifacts?name=$artifact&per_page=100" \
      --jq '.artifacts[] | select(.expired == false) | [.id, .workflow_run.head_sha] | @tsv')
  fi

  if [[ -z "$artifact_id" ]]; then
    echo "当前源码没有可用的 $artifact，无法准备 Flutter/Rust 桥接文件。" >&2
    exit 1
  fi

  archive="$(mktemp "${TMPDIR:-/tmp}/rustdesk-bridge.XXXXXX.zip")"
  if ! gh api "repos/rustdesk/rustdesk/actions/artifacts/$artifact_id/zip" > "$archive" 2>/dev/null; then
    gh api "repos/{owner}/{repo}/actions/artifacts/$artifact_id/zip" > "$archive"
  fi
  unzip -oq "$archive" -d "$ROOT"
}

sync_submodules() {
  if [[ ! -f "$ROOT/libs/hbb_common/Cargo.toml" ]]; then
    log "初始化 Git 子模块"
    git -C "$ROOT" submodule update --init --recursive
  fi
}

ensure_macos_resources() {
  local tray_icon="$ROOT/res/mac-tray-dark-x2.png"
  if [[ -s "$tray_icon" ]]; then
    return
  fi
  log "补齐 macOS 托盘图标"
  curl -fL --retry 3 \
    "https://raw.githubusercontent.com/rustdesk/rustdesk/b84058e07639006598f5fb624dad9dcd7b8cf96d/res/mac-tray-dark-x2.png" \
    -o "$tray_icon"
}

clear_stale_outputs() {
  log "清掉会让旧界面残留的产物"
  rm -rf "$APP_DEBUG"
  rm -rf "$PROD_DEBUG/RustDesk.swiftmodule"
  pkill -f "$APP_DEBUG/Contents/MacOS/RustDesk" 2>/dev/null || true
  if [[ "$CLEAN" -eq 1 ]]; then
    log "--clean：清掉 Flutter 构建缓存和 Rust debug 目标"
    (cd "$ROOT/flutter" && flutter clean) || true
    cargo clean
  fi
}

embed_pod_frameworks() {
  local app="$APP_DEBUG"
  local prod="$PROD_DEBUG"
  mkdir -p "$app/Contents/Frameworks"
  local src
  shopt -s nullglob
  for src in "$prod"/*/*.framework; do
    rsync -a "$src" "$app/Contents/Frameworks/"
  done
  shopt -u nullglob
  if [[ -f "$ROOT/target/debug/liblibrustdesk.dylib" ]]; then
    cp -f "$ROOT/target/debug/liblibrustdesk.dylib" "$app/Contents/Frameworks/liblibrustdesk.dylib"
  fi
}

require_xcode
sync_submodules
ensure_macos_resources
ensure_rust
ensure_flutter
ensure_nasm
ensure_vcpkg
ensure_bridge

if LLVM_HOME="$(detect_llvm_home)"; then
  export LLVM_HOME
fi
export VCPKG_ROOT
export PATH
prepend_path "$HOME/.cargo/bin"
prepend_path "$BIN_DIR"

log "拉取 Flutter Dart 依赖"
(cd "$ROOT/flutter" && flutter pub get)

if [[ -f "$ROOT/flutter/macos/Podfile" ]] && have pod; then
  log "安装 macOS CocoaPods"
  (cd "$ROOT/flutter/macos" && pod install)
elif [[ -f "$ROOT/flutter/macos/Podfile" ]]; then
  echo "未找到 pod。请安装 CocoaPods 后重试。" >&2
  exit 1
fi

clear_stale_outputs

log "编译 Rust 核心（增量）"
cargo build --locked --features flutter

# 这个仓库的 Xcode 工程把 liblibrustdesk.dylib 指向 target/release。
# Debug 启动也走这条路径，所以把刚编好的 debug 库放到它会读的位置。
mkdir -p "$ROOT/target/release"
cp -f "$ROOT/target/debug/liblibrustdesk.dylib" "$ROOT/target/release/liblibrustdesk.dylib"
if have install_name_tool; then
  install_name_tool -id @rpath/liblibrustdesk.dylib "$ROOT/target/release/liblibrustdesk.dylib" 2>/dev/null || true
fi

log "编译 Flutter macOS Debug"
(cd "$ROOT/flutter" && flutter build macos --debug)

embed_pod_frameworks

if [[ "$NO_RUN" -eq 1 ]]; then
  log "构建完成: $APP_DEBUG"
  exit 0
fi

if [[ ! -x "$APP_DEBUG/Contents/MacOS/RustDesk" ]]; then
  echo "构建失败，没有生成 $APP_DEBUG" >&2
  exit 1
fi

log "启动 RustDesk"
open "$APP_DEBUG"
