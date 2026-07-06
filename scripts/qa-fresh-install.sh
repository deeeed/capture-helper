#!/usr/bin/env bash
# Fresh-engineer QA for @siteed/capture-helper — run from repo root on the release branch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0
fail=0
note() { printf '\n==> %s\n' "$*"; }
ok() { pass=$((pass + 1)); echo "PASS: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

note "build universal native + sign"
npm run build:native >/tmp/capture-helper-qa-build.log 2>&1
lipo -info native/capture-helper | grep -q 'x86_64' && lipo -info native/capture-helper | grep -q 'arm64' \
  && ok "universal binary (arm64 + x86_64)" || bad "not universal"
test -f native/capture-helper.sha256 && ok "checksum sidecar present" || bad "missing checksum sidecar"

note "unit tests"
npm run test:js >/tmp/capture-helper-qa-js.log 2>&1 && ok "javascript tests" || bad "javascript tests"
swift test >/tmp/capture-helper-qa-swift.log 2>&1 && ok "swift tests" || bad "swift tests"

note "pack tarball (no swift on PATH during install)"
npm pack >/tmp/capture-helper-qa-pack.log 2>&1
TGZ="$(ls -1 siteed-capture-helper-*.tgz | sort -V | tail -1)"
test -n "$TGZ" && ok "packed ${TGZ}" || bad "npm pack failed"

STUB="$(mktemp -d)"
printf '#!/bin/sh\necho swift-stub >&2\nexit 1\n' >"${STUB}/swift"
chmod +x "${STUB}/swift"
export PATH="${STUB}:${PATH}"
unset SITEED_CAPTURE_HELPER_BIN CAPTURE_HELPER_PATH

npm uninstall -g @siteed/capture-helper >/dev/null 2>&1 || true
if npm install -g "./${TGZ}" >/tmp/capture-helper-qa-install.log 2>&1; then
  ok "global install from tarball (postinstall with stub swift)"
else
  bad "global install from tarball"
  cat /tmp/capture-helper-qa-install.log >&2
fi

GLOBAL_BIN="$(npm prefix -g)/bin/capture-helper"
NATIVE="$(npm root -g)/@siteed/capture-helper/native/capture-helper"
test -x "$NATIVE" && ok "native binary installed at ${NATIVE}" || bad "native binary missing"

note "version + doctor (human default)"
if "$GLOBAL_BIN" version | python3 -m json.tool >/dev/null 2>&1; then
  ok "capture-helper version"
else
  bad "capture-helper version"
fi

DOC_HUMAN="$("$GLOBAL_BIN" doctor 2>/dev/null || true)"
if printf '%s' "$DOC_HUMAN" | grep -q '^capture-helper doctor:'; then
  ok "doctor defaults to human output"
else
  bad "doctor human default (got: $(printf '%s' "$DOC_HUMAN" | head -1))"
fi

if "$GLOBAL_BIN" doctor --json 2>/dev/null | python3 -m json.tool >/dev/null; then
  ok "doctor --json parses"
else
  bad "doctor --json"
fi

note "farmslot resolution"
FSLOT="/Users/deeeed/dev/farmslot"
if [ -f "${FSLOT}/scripts/lib/capture-helper.sh" ]; then
  RESOLVED="$(FARMSLOT_CAPTURE_HELPER_REPO_ROOT="${FSLOT}" . "${FSLOT}/scripts/lib/capture-helper.sh" && resolve_capture_helper_bin)"
  if [ "$RESOLVED" = "$NATIVE" ]; then
    ok "farmslot resolve_capture_helper_bin → global npm native"
  else
    bad "farmslot resolved '${RESOLVED}' expected '${NATIVE}'"
  fi
else
  note "skip farmslot resolve (checkout not found)"
fi

note "broken binary teaches (human + json)"
PKG_ROOT="$(npm root -g)/@siteed/capture-helper"
mv "${PKG_ROOT}/native/capture-helper" "${PKG_ROOT}/native/capture-helper.qa.bak"
BROKEN_HUMAN="$("$GLOBAL_BIN" doctor 2>/dev/null || true)"
if printf '%s' "$BROKEN_HUMAN" | grep -q 'native_binary_missing'; then
  ok "broken doctor human reports native_binary_missing"
else
  bad "broken doctor human"
fi
BROKEN_JSON="$("$GLOBAL_BIN" doctor --json 2>/dev/null || true)"
if printf '%s' "$BROKEN_JSON" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["ok"] is False
assert "native_binary_missing" in doc["summary"]["requiredFailureCodes"]
assert doc["teach"]["brew"] == "brew install deeeed/tap/capture-helper"
'; then
  ok "broken doctor --json teaches brew path"
else
  bad "broken doctor --json"
  printf '%s\n' "$BROKEN_JSON" >&2
fi
mv "${PKG_ROOT}/native/capture-helper.qa.bak" "${PKG_ROOT}/native/capture-helper"

note "postinstall fails loud when binary missing and swift stubbed"
mv "${PKG_ROOT}/native/capture-helper" "${PKG_ROOT}/native/capture-helper.qa.bak"
if (cd "$PKG_ROOT" && node scripts/postinstall.js) >/tmp/capture-helper-qa-postinstall.log 2>&1; then
  bad "postinstall should fail when binary missing + no swift"
else
  if grep -q 'brew install deeeed/tap/capture-helper' /tmp/capture-helper-qa-postinstall.log; then
    ok "postinstall fails loud with teaching"
  else
    bad "postinstall failed but missing teaching"
    cat /tmp/capture-helper-qa-postinstall.log >&2
  fi
fi
mv "${PKG_ROOT}/native/capture-helper.qa.bak" "${PKG_ROOT}/native/capture-helper"

note "codesign"
CS_OUT="$(codesign -dv --verbose=2 "${ROOT}/native/capture-helper" 2>&1 || true)"
if printf '%s' "$CS_OUT" | grep -q 'Signature=adhoc'; then
  ok "adhoc signed release binary"
else
  bad "codesign state unexpected"
  printf '%s\n' "$CS_OUT" >&2
fi

printf '\n--- QA summary: %d passed, %d failed ---\n' "$pass" "$fail"
test "$fail" -eq 0