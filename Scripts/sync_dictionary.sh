#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXT_DICT_DIR="${ROOT_DIR}/../StudyMateDictionary"
EMBEDDED_DIR="${ROOT_DIR}/Embedded"
TARGET_APP="${EMBEDDED_DIR}/StudyMateDictionary.app"
TARGET_HELPER="${EMBEDDED_DIR}/studymate-dict"
DICT_SOURCES_DIR="${ROOT_DIR}/Sources/StudyMate/Dictionary"

echo "=== 开始同步外部词典应用与核心模块 (StudyMateDictionary) ==="

if [[ ! -d "${EXT_DICT_DIR}" ]]; then
    echo "❌ 错误: 未找到外部词典工程目录：${EXT_DICT_DIR}" >&2
    exit 1
fi

REBUILD=0
if [[ "${1:-}" == "--build" || "${1:-}" == "-b" || ! -d "${EXT_DICT_DIR}/dist/StudyMateDictionary.app" ]]; then
    REBUILD=1
elif [[ -d "${EXT_DICT_DIR}/Sources" && -n "$(find "${EXT_DICT_DIR}/Sources" "${EXT_DICT_DIR}/Dictionary" "${EXT_DICT_DIR}/Package.swift" -newer "${EXT_DICT_DIR}/dist/StudyMateDictionary.app" 2>/dev/null | head -n 1)" ]]; then
    echo "💡 检测到外部词典源码有更新，自动触发重新编译打包..."
    REBUILD=1
fi

if [[ "${REBUILD}" -eq 1 ]]; then
    echo "🔨 正在编译并打包外部词典程序..."
    (cd "${EXT_DICT_DIR}" && bash scripts/package_app.sh)
fi

SRC_APP="${EXT_DICT_DIR}/dist/StudyMateDictionary.app"

if [[ ! -d "${SRC_APP}" ]]; then
    echo "❌ 错误: 未找到打包好的词典应用：${SRC_APP}" >&2
    exit 1
fi

echo "📦 1. 正在同步词典应用至 ${TARGET_APP}..."
mkdir -p "${EMBEDDED_DIR}"
rm -rf "${TARGET_APP}"
ditto "${SRC_APP}" "${TARGET_APP}"

# 验证关键组件
EXECUTABLE="${TARGET_APP}/Contents/MacOS/StudyMateDictionary"
HELPER="${TARGET_APP}/Contents/Helpers/studymate-dict"
INFO_PLIST="${TARGET_APP}/Contents/Info.plist"

if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "❌ 错误: 同步后的主程序不可执行：${EXECUTABLE}" >&2
    exit 1
fi

if [[ ! -x "${HELPER}" ]]; then
    echo "❌ 错误: 同步后的辅助程序不可执行：${HELPER}" >&2
    exit 1
fi

echo "📦 2. 正在提取词典辅助引擎至 ${TARGET_HELPER}..."
cp -f "${HELPER}" "${TARGET_HELPER}"
chmod 755 "${TARGET_HELPER}"

echo "📦 3. 正在同步词典查询与自适应 HTML 渲染模块至 ${DICT_SOURCES_DIR}..."
mkdir -p "${DICT_SOURCES_DIR}"
SRC_ENGINE="${EXT_DICT_DIR}/Sources/StudyMateDictionary/Dictionary/DictionaryEngine.swift"
SRC_HTML_VIEW="${EXT_DICT_DIR}/Sources/StudyMateDictionary/Dictionary/DictionaryHTMLView.swift"
SRC_FIND_COORD="${EXT_DICT_DIR}/Sources/StudyMateDictionary/Dictionary/DictionaryFindCoordinator.swift"

if [[ -f "${SRC_ENGINE}" ]]; then
    cp -f "${SRC_ENGINE}" "${DICT_SOURCES_DIR}/DictionaryEngine.swift"
fi

if [[ -f "${SRC_HTML_VIEW}" ]]; then
    cp -f "${SRC_HTML_VIEW}" "${DICT_SOURCES_DIR}/DictionaryHTMLView.swift"
fi

if [[ -f "${SRC_FIND_COORD}" ]]; then
    cp -f "${SRC_FIND_COORD}" "${DICT_SOURCES_DIR}/DictionaryFindCoordinator.swift"
fi

# 检查 URL Scheme 注册
if ! plutil -p "${INFO_PLIST}" | grep -q "studymatedict"; then
    echo "⚠️ 警告: Info.plist 中未检测到 studymatedict URL Scheme" >&2
fi

# 重新签署 Embedded 实例
codesign --force --deep --sign "-" "${TARGET_APP}"
codesign --force --sign "-" "${TARGET_HELPER}"

DICT_VER=$(plutil -extract CFBundleShortVersionString raw "${INFO_PLIST}" 2>/dev/null || echo "unknown")
DICT_BUILD=$(plutil -extract CFBundleVersion raw "${INFO_PLIST}" 2>/dev/null || echo "unknown")
APP_SIZE=$(du -sh "${TARGET_APP}" | cut -f1)

echo "=========================================="
echo "🎉 词典应用与气泡弹窗引擎同步完成！"
echo "应用路径: ${TARGET_APP} (${APP_SIZE})"
echo "辅助引擎: ${TARGET_HELPER}"
echo "词典版本: ${DICT_VER} (Build ${DICT_BUILD})"
echo "=========================================="
