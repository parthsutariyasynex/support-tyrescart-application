#!/usr/bin/env bash
# Release APKs named after the app and the day they were built, e.g. apks/2026-10-31/TyresVision-CRM_2026-10-31.apk.
#
#   tool/build_apks.sh                 all three flavors (live, demo, crm)
#   tool/build_apks.sh crm demo        only these
#
# The app name is the flavor's appName in android/app/build.gradle.kts; the env file pairs with the flavor (env/README.md).
# Building the same app again on the same day replaces that day's APK.
set -euo pipefail
cd "$(dirname "$0")/.."

env_file() {
  case $1 in
    live) echo env/prod.json ;;
    demo) echo env/demo.json ;;
    crm) echo env/crm.json ;;
    *) echo "Unknown flavor: $1 (live, demo, crm)" >&2; exit 1 ;;
  esac
}

# appName of a flavor block in build.gradle.kts: create("crm") { … manifestPlaceholders["appName"] = "TyresVision CRM"
app_name() {
  awk -v f="create(\"$1\")" 'index($0, f) { on = 1 } on && /manifestPlaceholders\["appName"\]/ { split($0, q, "\""); print q[4]; exit }' \
    android/app/build.gradle.kts
}

DAY=$(date +%Y-%m-%d)
OUT=apks/$DAY
mkdir -p "$OUT"
FLAVORS=${*:-live demo crm}

for flavor in $FLAVORS; do
  env=$(env_file "$flavor")
  [ -f "$env" ] || { echo "Missing $env (see env/README.md)" >&2; exit 1; }
  name=$(app_name "$flavor")
  name=${name:-$flavor}
  echo "== $name ($flavor, $env)"
  flutter build apk --release --flavor "$flavor" --dart-define-from-file="$env"
  cp "build/app/outputs/flutter-apk/app-$flavor-release.apk" "$OUT/${name// /-}_$DAY.apk"
done

echo
echo "APKs in $(pwd)/$OUT:"
ls -lh "$OUT"
