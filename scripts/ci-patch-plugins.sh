#!/usr/bin/env bash
# Workaround for Flutter Android plugins that reference a `kotlin { }` block but
# never apply the Kotlin Gradle plugin (e.g. auto_orientation_v2 2.4.7,
# dynamic_color 1.9.0). Gradle then aborts with either
#   "Could not find method kotlin()"  or  "Unresolved reference: compilerOptions".
#
# The script patches the freshly downloaded copies inside PUB_CACHE right after
# `flutter pub get`, so upstream sources and the app code stay untouched.
#
# Usage: bash scripts/ci-patch-plugins.sh
set -uo pipefail

CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
PUBDIR="$CACHE/hosted/pub.dev"

if [ ! -d "$PUBDIR" ]; then
  echo "pub cache not found at $PUBDIR, nothing to do"
  exit 0
fi

patched=0
PYBIN="$(command -v python3 || command -v python || true)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  # only care about files that actually declare a kotlin { } block
  grep -qE '^[[:space:]]*kotlin[[:space:]]*\{' "$f" || continue
  # already correct
  grep -qE 'org\.jetbrains\.kotlin\.android|kotlin-android' "$f" && continue

  echo "--- patching $f"

  case "$f" in
    *.kts)
      if [ -n "$PYBIN" ]; then
        "$PYBIN" - "$f" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read()

def insert_after(pattern, text, anchor, addition):
    m = re.search(pattern, text)
    if not m:
        return None
    return text[:m.end()] + addition + text[m.end():]

# Prefer inserting right after the android library plugin id, so the Kotlin
# plugin is applied after AGP (required by the Kotlin Android plugin).
new = insert_after(r'id\(\s*[\'"]com\.android\.library[\'"]\s*\)[^\n]*\n', src, None,
                   '    id("org.jetbrains.kotlin.android")\n')
if new is None:
    new = insert_after(r'plugins\s*\{[^\n]*\n', src, None,
                       '    id("org.jetbrains.kotlin.android")\n')
if new is None:
    new = 'plugins {\n    id("com.android.library")\n    id("org.jetbrains.kotlin.android")\n}\n\n' + src
open(p, 'w', encoding='utf-8', newline='').write(new)
PY
      else
        # sed fallback: insert the id right after the plugins { opener
        sed -i '0,/plugins[[:space:]]*{/s|plugins[[:space:]]*{|plugins {\n    id("org.jetbrains.kotlin.android")|' "$f"
      fi
      ;;
    *)
      # Groovy DSL: apply the plugin right after the android library plugin
      if grep -q "apply plugin: 'com.android.library'" "$f"; then
        sed -i "0,/apply plugin: 'com.android.library'/s|apply plugin: 'com.android.library'|apply plugin: 'com.android.library'\napply plugin: 'org.jetbrains.kotlin.android'|" "$f"
      elif grep -q 'apply plugin: "com.android.library"' "$f"; then
        sed -i '0,/apply plugin: "com.android.library"/s|apply plugin: "com.android.library"|apply plugin: "com.android.library"\napply plugin: "org.jetbrains.kotlin.android"|' "$f"
      else
        printf "\napply plugin: 'org.jetbrains.kotlin.android'\n" >> "$f"
      fi
      ;;
  esac

  # Kotlin 2.x types jvmTarget as a JvmTarget enum; assigning a String throws
  # "Cannot set the value of property 'jvmTarget' ... using an instance of java.lang.String".
  sed -i \
    -e 's|jvmTarget = "JVM_1\.8"|jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)|g' \
    -e 's|jvmTarget = "JVM_17"|jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)|g' \
    -e 's|jvmTarget = "17"|jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)|g' \
    -e 's|jvmTarget = "1\.8"|jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)|g' \
    "$f"

  patched=$((patched + 1))
done < <(find "$PUBDIR" -maxdepth 5 -type f \( -name 'build.gradle' -o -name 'build.gradle.kts' \) 2>/dev/null | grep -E '/android/(build\.gradle|build\.gradle\.kts)$')

echo "patched $patched plugin build script(s)"
if [ "$patched" -eq 0 ]; then
  echo "no plugin needed patching"
fi
