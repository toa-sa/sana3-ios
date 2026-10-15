#!/bin/bash
#  check-publish.command — يفحص ملف IPA / TIPA قبل النشر: ما فيه أي أثر لشهادتك أو حسابك.
#  الاستخدام:  bash check-publish.command <ملف.ipa> [ملف ثاني...]
#  بدون ملفات يفحص كل ما في مجلد dist.
#  النتيجة: "✅ آمن للنشر" أو "⛔ لا تنشره" مع السبب.

cd "$(dirname "$0")"
[ $# -eq 0 ] && set -- dist/*.ipa dist/*.tipa
STATUS=0

for F in "$@"; do
  [ -f "$F" ] || continue
  echo "=== $(basename "$F")"
  T=$(mktemp -d)
  unzip -oq "$F" -d "$T" || { echo "⛔ ما قدرت أفتح الملف"; STATUS=1; continue; }
  BAD=()

  # 1) Provisioning profile = Team ID, name, bundle IDs, entitlements and (Dev / Ad Hoc) device UDIDs.
  while IFS= read -r p; do BAD+=("ملف تعريف مضمّن: ${p#$T/}"); done \
    < <(find "$T" \( -name "*.mobileprovision" -o -name "*.provisionprofile" \))

  # 2) Every signed part: only "not signed" or ad-hoc (no Authority, no Team ID) is allowed.
  while IFS= read -r b; do
    info=$(codesign -dvv "$b" 2>&1)
    if echo "$info" | grep -q "^Authority="; then
      BAD+=("موقّع بشهادة: ${b#$T/} ← $(echo "$info" | grep -m1 '^Authority=' | cut -d= -f2-)")
    fi
    team=$(echo "$info" | grep -m1 '^TeamIdentifier=' | cut -d= -f2)
    if [ -n "$team" ] && [ "$team" != "not set" ]; then
      BAD+=("Team ID ظاهر: ${b#$T/} ← $team")
    fi
    ent=$(codesign -d --entitlements - "$b" 2>/dev/null)
    if echo "$ent" | grep -qE "application-identifier|team-identifier|keychain-access-groups"; then
      BAD+=("صلاحيات فيها معرف الحساب: ${b#$T/}")
    fi
  done < <(find "$T/Payload" -maxdepth 4 \( -name "*.app" -o -name "*.appex" -o -name "*.framework" -o -name "*.dylib" \))

  # 3) Certificate names left anywhere in the files (signature blobs, plists).
  if grep -rlaE "Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution|ProvisionedDevices" "$T" >/dev/null 2>&1; then
    while IFS= read -r f; do BAD+=("اسم شهادة داخل: ${f#$T/}"); done \
      < <(grep -rlaE "Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution|ProvisionedDevices" "$T")
  fi

  # 4) Paths from the Mac (they show the Mac user name).
  while IFS= read -r f; do BAD+=("مسار من الماك داخل: ${f#$T/}"); done < <(grep -rla "/Users/" "$T")

  if [ ${#BAD[@]} -eq 0 ]; then
    sig=$(codesign -dvv "$T"/Payload/*.app 2>&1 | grep -m1 -E "^Signature=|not signed" | sed 's#.*: ##')
    echo "✅ آمن للنشر (التوقيع: ${sig:-غير موقّع})"
  else
    STATUS=1
    echo "⛔ لا تنشره:"
    printf '   • %s\n' "${BAD[@]}"
  fi
  rm -rf "$T"
done
exit $STATUS
