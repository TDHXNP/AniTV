#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-${PROJECT_ROOT}/AniTV.xcodeproj}"
SCHEME="${SCHEME:-AniTV}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-AniTV}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/scripts/output/user-signable-ipa}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${PROJECT_ROOT}/scripts/output/derived-data-user-signable}"
CLONED_SOURCE_PACKAGES_DIR_PATH="${CLONED_SOURCE_PACKAGES_DIR_PATH:-}"

SECRETS_PLIST_PATH="${SECRETS_PLIST_PATH:-}"
MARKETING_VERSION_OVERRIDE="${MARKETING_VERSION_OVERRIDE:-}"
CURRENT_PROJECT_VERSION_OVERRIDE="${CURRENT_PROJECT_VERSION_OVERRIDE:-}"

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-appletvos/${APP_NAME}.app"
PAYLOAD_DIR="${OUTPUT_DIR}/Payload"
IPA_NAME="${IPA_NAME:-${APP_NAME}-${CONFIGURATION}-user-signable-tvos.ipa}"
IPA_PATH="${OUTPUT_DIR}/${IPA_NAME}"

echo "==> Generating obfuscated secrets code"
SRCROOT="${PROJECT_ROOT}" SECRETS_PLIST_PATH="${SECRETS_PLIST_PATH}" python3 "${SCRIPT_DIR}/generate_secrets.py"

echo "==> Cleaning output directory"
rm -rf "${OUTPUT_DIR}"
mkdir -p "${PAYLOAD_DIR}"

XCODEBUILD_ARGS=(
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination 'generic/platform=tvOS'
  -derivedDataPath "${DERIVED_DATA_PATH}"
  -skipMacroValidation
)

if [[ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH}" ]]; then
  XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "${CLONED_SOURCE_PACKAGES_DIR_PATH}")
fi

XCODEBUILD_ARGS+=(
  build
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  AD_HOC_CODE_SIGNING_ALLOWED=NO
)

if [[ -n "${MARKETING_VERSION_OVERRIDE}" ]]; then
  XCODEBUILD_ARGS+=("MARKETING_VERSION=${MARKETING_VERSION_OVERRIDE}")
fi

if [[ -n "${CURRENT_PROJECT_VERSION_OVERRIDE}" ]]; then
  XCODEBUILD_ARGS+=("CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION_OVERRIDE}")
fi

echo "==> Building tvOS app without code signing"
xcodebuild "${XCODEBUILD_ARGS[@]}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "==> Verifying embedded Top Shelf extension and asset catalog"
if [[ ! -d "${APP_PATH}/PlugIns/AniTVTopShelf.appex" ]]; then
  echo "error: AniTVTopShelf.appex not embedded in ${APP_PATH}/PlugIns" >&2
  exit 1
fi
if [[ ! -f "${APP_PATH}/Assets.car" ]]; then
  echo "error: Assets.car missing in ${APP_PATH}" >&2
  exit 1
fi

echo "==> Packaging unsigned app into ipa"
cp -R "${APP_PATH}" "${PAYLOAD_DIR}/"
(
  cd "${OUTPUT_DIR}"
  ditto -c -k --sequesterRsrc --keepParent Payload "${IPA_NAME}"
  shasum -a 256 "${IPA_NAME}" > "${IPA_NAME}.sha256"
)

echo "==> Done"
echo "IPA: ${IPA_PATH}"
echo "SHA256: ${IPA_PATH}.sha256"
echo "Note: this IPA is not signed. Users still need to re-sign it with their own certificate/profile before installing."
