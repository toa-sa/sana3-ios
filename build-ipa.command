#!/bin/bash
# =====================================================================
#  Image Cleaner — بناء ملف IPA (بدون توقيع) — دبل كلك على الملف
# =====================================================================
set -eo pipefail
cd "$(dirname "$0")"

say() { printf "\n\033[1;32m▸ %s\033[0m\n" "$1"; }
fail() { printf "\n\033[1;31m✖ %s\033[0m\n\n" "$1"; read -n1 -r -p "اضغط أي زر للإغلاق…"; exit 1; }

# 1) Xcode
if ! xcodebuild -version >/dev/null 2>&1; then
  fail "لازم Xcode يكون مثبّت. لو مثبّت شغّل: sudo xcode-select -s /Applications/Xcode.app"
fi
xcodebuild -version | head -1

# 2) XcodeGen (يولّد ملف المشروع)
if ! command -v xcodegen >/dev/null 2>&1; then
  for p in /opt/homebrew/bin /usr/local/bin; do [ -x "$p/brew" ] && export PATH="$p:$PATH"; done
  if command -v brew >/dev/null 2>&1; then
    say "تثبيت XcodeGen…"
    brew install xcodegen
  else
    fail "يحتاج Homebrew لتثبيت XcodeGen: افتح https://brew.sh وثبّته، ثم أعد تشغيل هذا الملف"
  fi
fi

say "توليد مشروع Xcode…"
xcodegen generate --quiet

say "بناء التطبيق (Release)… ياخذ دقيقة أو دقيقتين"
rm -rf build dist
LOG="$(pwd)/build.log"
if ! xcodebuild -project ImageCleaner.xcodeproj \
      -target ImageCleaner \
      -configuration Release \
      -sdk iphoneos \
      SYMROOT="$(pwd)/build" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
      build > "$LOG" 2>&1; then
  grep -E "error:|fatal" "$LOG" | head -20
  fail "فشل البناء — راجع الأخطاء في الملف build.log"
fi

APP="build/Release-iphoneos/ImageCleaner.app"
[ -d "$APP" ] || fail "ما لقيت التطبيق بعد البناء"

say "تجهيز ملف IPA…"
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
( cd dist && zip -qry Sana3.ipa Payload )

# TrollStore (iOS 15 – 17.0, and jailbroken devices): same app with an ad-hoc ("fake")
# signature, which TrollStore replaces with its own at install time. No certificate needed.
say "تجهيز نسخة ترول ستور (TIPA)…"
codesign -f -s - --timestamp=none dist/Payload/ImageCleaner.app/PlugIns/ImageCleanerShare.appex >/dev/null 2>&1 \
  && codesign -f -s - --timestamp=none dist/Payload/ImageCleaner.app >/dev/null 2>&1 \
  || fail "فشل توقيع نسخة ترول ستور"
( cd dist && zip -qry Sana3-TrollStore.tipa Payload && rm -rf Payload )

# Never publish anything that carries a personal certificate, Team ID or provisioning profile.
say "فحص الخصوصية قبل النشر…"
bash ./check-publish.command dist/Sana3.ipa dist/Sana3-TrollStore.tipa \
  || fail "الملف فيه أثر لشهادتك أو حسابك — لا تنشره"

say "✅ تم: dist/Sana3.ipa  +  dist/Sana3-TrollStore.tipa"
echo "   Bundle IDs:  sa.toa.imagecleaner   +   sa.toa.imagecleaner.share (Share Extension)"
echo "   Sana3.ipa: غير موقّع — للنشر. كل مستخدم يوقّعه بنفسه (لا تنشر نسخة موقّعة بشهادتك)."
echo "   Sana3-TrollStore.tipa: افتحه بترول ستور مباشرة (iOS 15 لين 17.0 أو جهاز عليه جلبريك)."
open dist
