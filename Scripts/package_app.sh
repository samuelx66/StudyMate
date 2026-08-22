#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="MacAboboo"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cd "${ROOT_DIR}"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少发布工具：$1" >&2
        exit 1
    }
}

for tool in swift otool install_name_tool codesign iconutil ditto lipo; do
    require_tool "${tool}"
done

echo "=== 1. 编译 Release 二进制 ==="
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="${BUILD_DIR}/${APP_NAME}"
test -x "${EXECUTABLE}" || { echo "未找到 Release 可执行文件：${EXECUTABLE}" >&2; exit 1; }
APP_ARCHS="$(lipo -archs "${EXECUTABLE}")"
ARCH_LABEL="$(echo "${APP_ARCHS}" | tr ' ' '-')"

echo "=== 2. 创建干净的 App Bundle（${APP_ARCHS}） ==="
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"
cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
chmod 755 "${MACOS_DIR}/${APP_NAME}"

RESOURCE_BUNDLE="${BUILD_DIR}/MacAboboo_MacAbobooKit.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${RESOURCES_DIR}/"
fi

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
done < <(find "${FRAMEWORKS_DIR}" "${HELPERS_DIR}" -type f -print0)

echo "=== 5. 生成图标与应用元数据 ==="
ICON_TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${ICON_TEMP_DIR}"' EXIT
ICONSET="${ICON_TEMP_DIR}/AppIcon.iconset"
swift "${SCRIPT_DIR}/generate_icon.swift" "${ICONSET}"
iconutil -c icns "${ICONSET}" -o "${RESOURCES_DIR}/AppIcon.icns"

cp "${ROOT_DIR}/Sources/MacAbobooApp/Info.plist" "${CONTENTS_DIR}/Info.plist"
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
    codesign "${SIGN_OPTIONS[@]}" "${nested}"
done < <(find "${FRAMEWORKS_DIR}" -type f -print0)
codesign "${SIGN_OPTIONS[@]}" "${HELPERS_DIR}/ffmpeg"
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
