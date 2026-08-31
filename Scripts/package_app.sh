#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="StudyMate"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MODULE_BUNDLE_NAME="StudyMate_StudyMateKit.bundle"
MODULE_BUNDLE_DEST="${RESOURCES_DIR}/${MODULE_BUNDLE_NAME}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cd "${ROOT_DIR}"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少发布工具：$1" >&2
        exit 1
    }
}

for tool in swift cargo otool install_name_tool codesign actool ditto lipo; do
    require_tool "${tool}"
done

echo "=== 0. 同步更新 Xcode 工程配置 ==="
python3 "${ROOT_DIR}/Scripts/generate_xcodeproj.py"

echo "=== 1. 编译 Release 二进制 ==="
swift build -c release --disable-sandbox
BUILD_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
EXECUTABLE="${BUILD_DIR}/${APP_NAME}"
test -x "${EXECUTABLE}" || { echo "未找到 Release 可执行文件：${EXECUTABLE}" >&2; exit 1; }
APP_ARCHS="$(lipo -archs "${EXECUTABLE}")"
ARCH_LABEL="$(echo "${APP_ARCHS}" | tr ' ' '-')"

echo "=== 2. 创建干净的 App Bundle（${APP_ARCHS}） ==="
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"
cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
chmod 755 "${MACOS_DIR}/${APP_NAME}"

echo "=== 2.1 编译并内置词典桥接程序 ==="
cargo build --manifest-path "${ROOT_DIR}/Dictionary/Cargo.toml" --release --bin studymate-dict
DICT_HELPER="${ROOT_DIR}/Dictionary/target/release/studymate-dict"
test -x "${DICT_HELPER}" || {
    echo "未找到词典桥接程序：${DICT_HELPER}" >&2
    exit 1
}
cp "${DICT_HELPER}" "${HELPERS_DIR}/studymate-dict"
chmod 755 "${HELPERS_DIR}/studymate-dict"
if ! otool -l "${MACOS_DIR}/${APP_NAME}" | grep -Fq '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "${MACOS_DIR}/${APP_NAME}"
fi
while IFS= read -r development_rpath; do
    case "${development_rpath}" in
        /Applications/Xcode.app/*|/Users/*)
            install_name_tool -delete_rpath "${development_rpath}" "${MACOS_DIR}/${APP_NAME}"
            ;;
    esac
done < <(otool -l "${MACOS_DIR}/${APP_NAME}" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { reading_rpath = 1; next }
    reading_rpath && $1 == "path" { print $2; reading_rpath = 0 }
')

RESOURCE_BUNDLE="${BUILD_DIR}/StudyMate_StudyMateKit.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    # 资源包放在标准的 Contents/Resources，由 StudyMateResourceBundle 显式加载。
    # 不要把它放到 .app 根目录，否则 codesign 会将其视为未封装内容。
    cp -R "${RESOURCE_BUNDLE}" "${MODULE_BUNDLE_DEST}"
    # SwiftPM 的增量资源目录可能残留旧版 CLI/Metal 文件；新版仅使用进程内框架。
    rm -f \
        "${MODULE_BUNDLE_DEST}/whisper-cli" \
        "${MODULE_BUNDLE_DEST}/ggml-metal.metal"
else
    echo "未找到 SwiftPM 资源包：${RESOURCE_BUNDLE}" >&2
    exit 1
fi
test -d "${MODULE_BUNDLE_DEST}" || {
    echo "资源包未放在 Bundle.module 需要的位置：${MODULE_BUNDLE_DEST}" >&2
    exit 1
}

WHISPER_FRAMEWORK="${BUILD_DIR}/whisper.framework"
[[ -d "${WHISPER_FRAMEWORK}" ]] || {
    echo "未找到进程内 Whisper 运行框架：${WHISPER_FRAMEWORK}" >&2
    exit 1
}
ditto "${WHISPER_FRAMEWORK}" "${FRAMEWORKS_DIR}/whisper.framework"

resolve_dependency() {
    local dependency="$1"
    local origin="$2"
    local leaf candidate
    if [[ "${dependency}" == /* ]]; then
        [[ -f "${dependency}" ]] && echo "${dependency}"
        return
    fi
    leaf="$(basename "${dependency}")"
    if [[ "${dependency}" == @loader_path/* ]]; then
        candidate="$(dirname "${origin}")/${dependency#@loader_path/}"
        [[ -f "${candidate}" ]] && echo "${candidate}"
        return
    fi
    for candidate in \
        "$(dirname "${origin}")/${leaf}" \
        "/opt/homebrew/lib/${leaf}" \
        "/usr/local/lib/${leaf}"; do
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return
        fi
    done
    candidate="$(find /opt/homebrew/opt /usr/local/opt -path "*/lib/${leaf}" -type f -print -quit 2>/dev/null || true)"
    [[ -n "${candidate}" ]] && echo "${candidate}"
}

is_system_dependency() {
    [[ "$1" == /System/* || "$1" == /usr/lib/* ]]
}

copy_library() {
    local source="$1"
    local basename destination dependency resolved replacement
    basename="$(basename "${source}")"
    destination="${FRAMEWORKS_DIR}/${basename}"
    [[ -f "${destination}" ]] && return

    cp -L "${source}" "${destination}"
    chmod 755 "${destination}"
    install_name_tool -id "@rpath/${basename}" "${destination}" 2>/dev/null || true

    while IFS= read -r dependency; do
        [[ -z "${dependency}" ]] && continue
        is_system_dependency "${dependency}" && continue
        resolved="$(resolve_dependency "${dependency}" "${source}")"
        if [[ -z "${resolved}" ]]; then
            echo "无法解析 ${basename} 的动态依赖：${dependency}" >&2
            exit 1
        fi
        copy_library "${resolved}"
        replacement="@loader_path/$(basename "${resolved}")"
        install_name_tool -change "${dependency}" "${replacement}" "${destination}"
    done < <(otool -L "${source}" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
}

rewrite_executable_dependencies() {
    local source="$1"
    local destination="$2"
    local relative_frameworks="$3"
    local dependency resolved
    while IFS= read -r dependency; do
        [[ -z "${dependency}" ]] && continue
        is_system_dependency "${dependency}" && continue
        resolved="$(resolve_dependency "${dependency}" "${source}")"
        if [[ -z "${resolved}" ]]; then
            echo "无法解析 $(basename "${source}") 的动态依赖：${dependency}" >&2
            exit 1
        fi
        copy_library "${resolved}"
        install_name_tool -change "${dependency}" "${relative_frameworks}/$(basename "${resolved}")" "${destination}"
    done < <(otool -L "${source}" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
}

echo "=== 3. 打包 libmpv、ffmpeg 及其非系统依赖 ==="
MPV_SOURCE="${LIBMPV_PATH:-}"
if [[ -z "${MPV_SOURCE}" ]]; then
    for candidate in /opt/homebrew/lib/libmpv.2.dylib /usr/local/lib/libmpv.2.dylib /opt/homebrew/lib/libmpv.dylib /usr/local/lib/libmpv.dylib; do
        if [[ -f "${candidate}" ]]; then MPV_SOURCE="${candidate}"; break; fi
    done
fi
[[ -f "${MPV_SOURCE}" ]] || {
    echo "发布包必须包含 libmpv。请安装 mpv，或通过 LIBMPV_PATH 指定 libmpv.2.dylib。" >&2
    exit 1
}
copy_library "${MPV_SOURCE}"

FFMPEG_SOURCE="${FFMPEG_PATH:-}"
if [[ -z "${FFMPEG_SOURCE}" ]]; then
    for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
        if [[ -x "${candidate}" ]]; then FFMPEG_SOURCE="${candidate}"; break; fi
    done
fi
[[ -x "${FFMPEG_SOURCE}" ]] || {
    echo "发布包必须包含 ffmpeg 波形辅助程序。请安装 ffmpeg，或通过 FFMPEG_PATH 指定。" >&2
    exit 1
}
cp -L "${FFMPEG_SOURCE}" "${HELPERS_DIR}/ffmpeg"
chmod 755 "${HELPERS_DIR}/ffmpeg"
rewrite_executable_dependencies "${FFMPEG_SOURCE}" "${HELPERS_DIR}/ffmpeg" "@loader_path/../Frameworks"

echo "=== 4. 校验架构与动态库路径 ==="
while IFS= read -r -d '' binary; do
    if file "${binary}" | grep -q 'Mach-O'; then
        BINARY_ARCHS="$(lipo -archs "${binary}")"
        for required_arch in ${APP_ARCHS}; do
            echo " ${BINARY_ARCHS} " | grep -q " ${required_arch} " || {
                echo "架构不匹配：${binary} 缺少 ${required_arch}" >&2
                exit 1
            }
        done
        if otool -L "${binary}" | tail -n +2 | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
            echo "仍有 Homebrew 绝对依赖未改写：${binary}" >&2
            otool -L "${binary}" >&2
            exit 1
        fi
    fi
done < <(find "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${HELPERS_DIR}" -type f -print0)

otool -l "${MACOS_DIR}/${APP_NAME}" | grep -Fq '@executable_path/../Frameworks' || {
    echo "主程序缺少内置 Frameworks 运行时搜索路径。" >&2
    exit 1
}
if otool -l "${MACOS_DIR}/${APP_NAME}" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { reading_rpath = 1; next }
    reading_rpath && $1 == "path" { print $2; reading_rpath = 0 }
' | grep -E '^(/Users/|/Applications/Xcode\.app/)' >/dev/null; then
    echo "主程序仍包含本机开发环境的运行时搜索路径。" >&2
    exit 1
fi

echo "=== 5. 生成图标与应用元数据 ==="
ICON_TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${ICON_TEMP_DIR}"' EXIT
ACTOOL_OUTPUT="${ICON_TEMP_DIR}/compiled-assets"
mkdir -p "${ACTOOL_OUTPUT}"
actool \
    --compile "${ACTOOL_OUTPUT}" \
    --app-icon AppIcon \
    --output-partial-info-plist "${ICON_TEMP_DIR}/partial-info.plist" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    "${ROOT_DIR}/Sources/StudyMate/Resources/Assets.xcassets" >/dev/null
test -f "${ACTOOL_OUTPUT}/AppIcon.icns" || {
    echo "未生成应用图标：${ACTOOL_OUTPUT}/AppIcon.icns" >&2
    exit 1
}
cp "${ACTOOL_OUTPUT}/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

cp "${ROOT_DIR}/Sources/StudyMateApp/Info.plist" "${CONTENTS_DIR}/Info.plist"
for localization in en.lproj zh-Hans.lproj; do
    mkdir -p "${RESOURCES_DIR}/${localization}"
    cp "${ROOT_DIR}/Sources/StudyMateApp/${localization}/InfoPlist.strings" "${RESOURCES_DIR}/${localization}/InfoPlist.strings"
done
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${CONTENTS_DIR}/Info.plist")"

echo "=== 6. 签名并验证 ==="
SIGN_OPTIONS=(--force --sign "${SIGN_IDENTITY}")
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    SIGN_OPTIONS+=(--options runtime --timestamp)
else
    SIGN_OPTIONS+=(--timestamp=none)
    echo "提示：未设置 CODESIGN_IDENTITY，本次生成的是本机测试用 ad-hoc 包。"
fi
while IFS= read -r -d '' nested; do
    if file "${nested}" | grep -q 'Mach-O'; then
        codesign "${SIGN_OPTIONS[@]}" "${nested}"
    fi
done < <(find "${FRAMEWORKS_DIR}" -type f -print0)
while IFS= read -r -d '' framework; do
    codesign "${SIGN_OPTIONS[@]}" "${framework}"
done < <(find "${FRAMEWORKS_DIR}" -type d -name '*.framework' -print0)
while IFS= read -r -d '' helper; do
    if file "${helper}" | grep -q 'Mach-O'; then
        codesign "${SIGN_OPTIONS[@]}" "${helper}"
    fi
done < <(find "${HELPERS_DIR}" -type f -print0)
codesign "${SIGN_OPTIONS[@]}" "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

ZIP_PATH="${DIST_DIR}/${APP_NAME}-v${VERSION}-macOS-${ARCH_LABEL}.zip"
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

if [[ -n "${NOTARY_PROFILE}" ]]; then
    [[ "${SIGN_IDENTITY}" != "-" ]] || { echo "公证要求设置 Developer ID CODESIGN_IDENTITY。" >&2; exit 1; }
    echo "=== 7. 提交 Apple 公证并装订 ==="
    xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP_BUNDLE}"
    rm -f "${ZIP_PATH}"
    ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"
fi

echo "发布包已生成：${ZIP_PATH}"
ls -lh "${APP_BUNDLE}" "${ZIP_PATH}"
