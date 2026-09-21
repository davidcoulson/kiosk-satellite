#!/usr/bin/env bash
# Onboard a new wall panel into this house: debloat, install Kiosk Satellite,
# clone the house profile off an existing panel, and prove the result.
#
# What this cannot do is everything before ADB works: unlocking the
# bootloader, rooting with Magisk, joining Wi-Fi and turning on USB debugging
# are physical, device-specific, and in the bootloader's case destructive.
# docs/panel-onboarding.md covers those; this script picks up after them.
#
# Every phase is separately runnable and safe to re-run. Nothing that removes
# or overwrites anything happens without --apply.
#
#   ./tool/onboard-panel.sh preflight
#   ./tool/onboard-panel.sh debloat-scan
#   ./tool/onboard-panel.sh debloat --apply
#   ./tool/onboard-panel.sh tcpip
#   ./tool/onboard-panel.sh install --apk build/app/outputs/flutter-apk/app-release.apk
#   ./tool/onboard-panel.sh provision --from 10.2.4.145 \
#       --name 'Kitchen Panel' --dashboard https://home-iot.coulson.io/kitchen/main
#   ./tool/onboard-panel.sh verify
set -euo pipefail

PKG=me.jxl.kiosk_satellite
ADMIN_PORT=2324

TARGET="${KS_TARGET:-}"        # adb serial: USB id, or ip:5555
SOURCE="${KS_SOURCE:-}"        # panel to copy the house profile from
NAME=""; DASHBOARD=""; SATELLITE=""; HOSTNAME=""; APK=""
APPLY=0
PW_FILE="${KS_PW_FILE:-$HOME/Desktop/ks-remote-pw.txt}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }

# The admin password. Never passed on a command line, where it would land in
# the shell history and in ps output.
password() {
  if [[ -n "${KS_REMOTE_PW:-}" ]]; then printf '%s' "$KS_REMOTE_PW"; return; fi
  [[ -f "$PW_FILE" ]] || die "no password: set KS_REMOTE_PW or put one in $PW_FILE"
  tr -d '\n\r' < "$PW_FILE"
}

adbt() { adb -s "$TARGET" "$@"; }

pick_target() {
  [[ -n "$TARGET" ]] && return
  local found
  found=$(adb devices | awk '$2=="device"{print $1}')
  [[ -z "$found" ]] && die "no adb device. Connect USB, accept the debugging prompt, and retry."
  [[ $(wc -l <<<"$found") -gt 1 ]] && die "several devices; pass --target <serial>:"$'\n'"$found"
  TARGET="$found"
}

# A device's IP on the wire, for the admin API once ADB over TCP is up.
device_ip() {
  adbt shell ip route 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' | tr -d '\r'
}

api() { # api <ip> <token> <method> <path> [body]
  local ip=$1 token=$2 method=$3 path=$4 body=${5:-}
  if [[ -n "$body" ]]; then
    curl -sS -m 30 -X "$method" "http://$ip:$ADMIN_PORT$path" \
      -H "authorization: Bearer $token" -H 'content-type: application/json' -d "$body"
  else
    curl -sS -m 30 -X "$method" "http://$ip:$ADMIN_PORT$path" -H "authorization: Bearer $token"
  fi
}

login() { # login <ip> -> token on stdout
  local ip=$1 pw; pw=$(password)
  curl -sS -m 20 -X POST "http://$ip:$ADMIN_PORT/api/login" \
    -H 'content-type: application/json' \
    --data-binary "$(python3 -c 'import json,sys;print(json.dumps({"password":sys.argv[1]}))' "$pw")" |
    python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'
}

wait_for_admin() { # wait_for_admin <ip> [seconds]
  local ip=$1 limit=${2:-180} i=0
  while ! curl -s -m 4 "http://$ip:$ADMIN_PORT/api/health" >/dev/null 2>&1; do
    i=$((i+5)); [[ $i -ge $limit ]] && die "remote admin never answered on $ip"
    sleep 5
  done
}

# ── phases ───────────────────────────────────────────────────────────────

phase_preflight() {
  pick_target
  say "Device"
  local sdk rel model brand abi root
  sdk=$(adbt shell getprop ro.build.version.sdk | tr -d '\r')
  rel=$(adbt shell getprop ro.build.version.release | tr -d '\r')
  model=$(adbt shell getprop ro.product.model | tr -d '\r')
  brand=$(adbt shell getprop ro.product.brand | tr -d '\r')
  abi=$(adbt shell getprop ro.product.cpu.abilist | tr -d '\r')
  note "$brand $model — Android $rel (API $sdk)"
  note "ABIs: $abi"
  note "IP: $(device_ip)"
  root=$(adbt shell 'su -c id' 2>&1 | tr -d '\r' || true)
  if [[ "$root" == *"uid=0"* ]]; then
    note "root: yes ($(adbt shell 'su -c "magisk -V"' 2>/dev/null | tr -d '\r' || echo 'no magisk binary'))"
  else
    warn "root: no. Magisk is not installed — see docs/panel-onboarding.md."
  fi
  [[ "$sdk" -lt 24 ]] && warn "Android is older than the app supports (API 24)."
  say "Checks"
  local enc; enc=$(adbt shell getprop ro.crypto.state | tr -d '\r')
  note "storage encryption: ${enc:-unknown}"
  note "packages installed: $(adbt shell pm list packages 2>/dev/null | wc -l | tr -d ' ')"
}

# Everything the panel does not need. Proposed, never applied here: which
# vendor packages matter is a judgement about this hardware, and a wrong
# guess is a device that will not boot.
phase_debloat_scan() {
  pick_target
  local out=${KS_DEBLOAT_LIST:-./debloat-candidates.txt}
  say "Third-party and vendor packages"
  # Keep: the app, anything Android's own, the input method (no keyboard =
  # no way to type a Wi-Fi password on the device), and Magisk.
  adbt shell 'pm list packages -3; pm list packages -s' 2>/dev/null |
    sed 's/^package://' | tr -d '\r' | sort -u |
    grep -vE '^(android|com\.android\.|com\.google\.android\.(gms|gsf|webview|packageinstaller|permissioncontroller|inputmethod)|me\.jxl\.kiosk_satellite$|com\.topjohnwu\.magisk$)' \
    > "$out" || true
  local n; n=$(wc -l < "$out" | tr -d ' ')
  note "wrote $n candidates to $out"
  say "Review before applying"
  note "Delete from that file anything the panel needs, then:"
  note "  $0 debloat --apply"
  note "Keep a launcher and an input method unless the kiosk fully replaces them."
  head -25 "$out" | sed 's/^/    /'
  [[ $n -gt 25 ]] && note "    ... $((n-25)) more"
}

phase_debloat() {
  pick_target
  local list=${KS_DEBLOAT_LIST:-./debloat-candidates.txt}
  [[ -f "$list" ]] || die "no $list — run '$0 debloat-scan' first and review it"
  [[ $APPLY -eq 1 ]] || { say "Dry run"; note "would remove $(wc -l < "$list" | tr -d ' ') package(s); pass --apply"; sed 's/^/    /' "$list"; return; }
  say "Removing for the current user (reversible; the APK stays in the image)"
  local pkg
  while read -r pkg; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    if adbt shell pm uninstall -k --user 0 "$pkg" 2>&1 | grep -q Success; then
      note "removed  $pkg"
    elif adbt shell pm disable-user --user 0 "$pkg" 2>&1 | grep -q "new state"; then
      note "disabled $pkg"
    else
      warn "left     $pkg (protected; a Magisk module can hide it — see the doc)"
    fi
  done < "$list"
  note "To restore one: adb -s $TARGET shell cmd package install-existing <pkg>"
}

phase_tcpip() {
  pick_target
  say "ADB over TCP"
  adbt tcpip 5555 >/dev/null 2>&1 || die "could not switch to TCP mode"
  sleep 2
  local ip; ip=$(device_ip)
  [[ -z "$ip" ]] && die "device has no IP yet — join Wi-Fi first"
  note "listening on $ip:5555"
  note "Give it a DHCP reservation, then: adb connect $ip:5555"
  note "Reachable only from the trusted LAN; the panel VLAN blocks 5555 from elsewhere."
}

phase_install() {
  pick_target
  [[ -n "$APK" ]] || APK=$(ls -t app/build/app/outputs/flutter-apk/app-release.apk 2>/dev/null | head -1 || true)
  [[ -f "${APK:-}" ]] || die "no APK: pass --apk <path> (build with: cd app && flutter build apk --release --target-platform android-arm64)"
  say "Installing $(basename "$APK")"
  local abis extra
  abis=$(adbt shell getprop ro.product.cpu.abilist | tr -d '\r')
  # An APK carrying ABIs this device cannot run is not wrong, only large,
  # and over a panel's Wi-Fi large is slow. Say so rather than refuse.
  extra=$(unzip -l "$APK" 'lib/*' 2>/dev/null | awk '{split($4,p,"/"); if (p[2]!="") print p[2]}' | sort -u |
    while read -r abi; do [[ ",$abis," == *",$abi,"* ]] || printf '%s ' "$abi"; done)
  [[ -n "$extra" ]] && warn "APK also carries ${extra}which this device cannot use — build with --target-platform android-arm64 to halve it"
  adbt install -r "$APK" | tail -1

  say "Runtime permissions"
  local sdk; sdk=$(adbt shell getprop ro.build.version.sdk | tr -d '\r')
  local perms=(RECORD_AUDIO CAMERA ACCESS_COARSE_LOCATION ACCESS_FINE_LOCATION)
  [[ "$sdk" -ge 31 ]] && perms+=(BLUETOOTH_SCAN BLUETOOTH_CONNECT)
  [[ "$sdk" -ge 33 ]] && perms+=(POST_NOTIFICATIONS READ_MEDIA_IMAGES READ_MEDIA_VIDEO)
  [[ "$sdk" -lt 33 ]] && perms+=(READ_EXTERNAL_STORAGE)
  [[ "$sdk" -lt 30 ]] && perms+=(WRITE_EXTERNAL_STORAGE)
  for p in "${perms[@]}"; do
    adbt shell pm grant "$PKG" "android.permission.$p" 2>/dev/null && note "granted $p" || warn "skipped $p (not on this Android)"
  done

  say "Special access"
  adbt shell appops set "$PKG" SYSTEM_ALERT_WINDOW allow 2>/dev/null && note "display over other apps"
  adbt shell appops set "$PKG" WRITE_SETTINGS allow 2>/dev/null && note "modify system settings (hardware brightness)"
  [[ "$sdk" -ge 30 ]] && adbt shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow 2>/dev/null && note "all files access"
  adbt shell appops set "$PKG" GET_USAGE_STATS allow 2>/dev/null && note "usage access (foreground-app sensor)"
  adbt shell dumpsys deviceidle whitelist "+$PKG" >/dev/null 2>&1 && note "battery exemption (survives reboot)"
  adbt shell dpm set-active-admin "$PKG/.KioskAdminReceiver" >/dev/null 2>&1 && note "device admin (true screen off)" || warn "device admin refused — set it in Settings > Security"

  # Overwrites the list, which is empty on a dedicated panel. Checked rather
  # than assumed, because clobbering a screen reader would be cruel.
  local existing
  existing=$(adbt shell settings get secure enabled_accessibility_services | tr -d '\r')
  if [[ "$existing" == "null" || -z "$existing" ]]; then
    adbt shell settings put secure enabled_accessibility_services "$PKG/$PKG.KioskAccessibilityService" >/dev/null
    adbt shell settings put secure accessibility_enabled 1 >/dev/null
    note "system UI guard (accessibility)"
  else
    warn "accessibility services already set ($existing) — add the guard by hand"
  fi
  say "Done. Launch it once so it can finish setting up:"
  note "adb -s $TARGET shell monkey -p $PKG -c android.intent.category.LAUNCHER 1"
}

phase_provision() {
  pick_target
  [[ -n "$SOURCE" ]] || die "--from <ip of an existing panel> is required"
  [[ -n "$NAME" ]] || die "--name 'Kitchen Panel' is required"
  [[ -n "$DASHBOARD" ]] || die "--dashboard <url> is required"
  local pw; pw=$(password)
  local ip; ip=$(device_ip)
  [[ -n "$ip" ]] || die "device has no IP"

  say "Bootstrapping the remote admin"
  # Smallest possible step: the admin server, so everything after it can go
  # over HTTP instead of through intent extras, which the shell would have to
  # quote and the Binder would cap.
  adbt shell am start -n "$PKG/.MainActivity" \
    --es ks.provision "$(python3 -c 'import json,sys;print(json.dumps({"remote.enabled":True,"remote.password":sys.argv[1]}))' "$pw")" >/dev/null
  wait_for_admin "$ip"
  local token; token=$(login "$ip")
  [[ -n "$token" ]] || die "could not log in to the new panel"
  note "admin answering on $ip:$ADMIN_PORT"

  say "Copying the house profile from $SOURCE"
  local src_token; src_token=$(login "$SOURCE")
  [[ -n "$src_token" ]] || die "could not log in to $SOURCE"
  local profile; profile=$(mktemp)
  trap 'rm -f "$profile"' RETURN            # it holds the HA token in the clear
  chmod 600 "$profile"
  api "$SOURCE" "$src_token" GET /api/config/export |
    python3 -c 'import sys,json; d=json.load(sys.stdin); json.dump(d.get("settings",d), sys.stdout)' > "$profile"
  note "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$profile") settings"

  # adoptIdentity=0 sheds the source's name, hostname, ESPHome node name,
  # Sendspin player id, fleet membership and Voice Satellite entity, which
  # are the things two panels must not share.
  local applied
  applied=$(curl -sS -m 60 -X POST "http://$ip:$ADMIN_PORT/api/settings/import?adoptIdentity=0" \
    -H "authorization: Bearer $token" -H 'content-type: application/json' \
    --data-binary "@$profile")
  note "imported: $applied"

  say "This panel's own identity"
  [[ -z "$HOSTNAME" ]] && HOSTNAME="ks-$(tr '[:upper:] ' '[:lower:]-' <<<"$NAME")"
  [[ -z "$SATELLITE" ]] && SATELLITE="assist_satellite.$(tr '[:upper:] ' '[:lower:]_' <<<"$NAME")"
  local perdevice
  perdevice=$(python3 - "$NAME" "$DASHBOARD" "$HOSTNAME" "$SATELLITE" <<'PY'
import json,sys
name,dash,host,sat=sys.argv[1:5]
print(json.dumps({
  "device.name": name,
  "device.hostname": host,
  "browser.start_url": dash,
  "ha.satellite_entity": sat,
  # Left empty on purpose: the next start names the node after the device
  # name, which keeps mDNS unique without anybody choosing a hex suffix.
  "esphome.node_name": "",
}))
PY
)
  api "$ip" "$token" PATCH /api/settings "$perdevice" | head -c 300; echo
  note "name: $NAME"; note "dashboard: $DASHBOARD"; note "hostname: $HOSTNAME"; note "satellite: $SATELLITE"
  say "Next"
  note "Restart the app so the ESPHome node name and hostname take: $0 verify --restart"
  note "Then adopt it in Home Assistant (ESPHome will offer it) and set the Voice Satellite entity there."
}

phase_verify() {
  pick_target
  local ip; ip=$(device_ip)
  [[ -n "$ip" ]] || die "device has no IP"
  if [[ $APPLY -eq 1 ]]; then
    say "Cold restart"
    adbt logcat -c 2>/dev/null || true
    adbt shell am force-stop "$PKG"; sleep 3
    adbt shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    wait_for_admin "$ip"; sleep 8
  fi
  local token; token=$(login "$ip")
  say "Panel"
  curl -sS -m 15 "http://$ip:$ADMIN_PORT/api/health" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  {} - {} on {} ({})".format(
    d["name"], d["appVersion"], d["model"], d["androidVersion"]))
'
  say "Credentials survive a restart"
  [[ -n "$token" ]] && note "admin login: OK" || warn "admin login FAILED"
  local wrong
  wrong=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "http://$ip:$ADMIN_PORT/api/login" \
    -H 'content-type: application/json' -d '{"password":"definitely-not-it"}')
  [[ "$wrong" == "401" ]] && note "wrong password refused (401)" || warn "wrong password got $wrong"
  # Secrets must be wrapped on disk, not merely working.
  local sealed
  sealed=$(adbt shell "su -c 'cat /data/data/$PKG/shared_prefs/FlutterSharedPreferences.xml'" 2>/dev/null |
    grep -c 'ksv1:' || true)
  if [[ "${sealed:-0}" -gt 0 ]]; then note "secrets wrapped in the Keystore: $sealed"
  else warn "no wrapped secrets found (no root, or the Keystore self-test failed — check the log)"; fi
  say "Connections"
  note "haStatus: $(api "$ip" "$token" POST /api/commands/haStatus '{}')"
  adbt logcat -d 2>/dev/null | grep -E 'KsEsphome: session #|KsBtProxy: scan started' | tail -2 | sed 's/^/  /' || warn "no ESPHome/Bluetooth lines yet"
  local bad
  bad=$(adbt logcat -d 2>/dev/null | grep -icE 'protected setting|could not protect|could not be read' || true)
  [[ "${bad:-0}" == "0" ]] && note "no secret-store complaints" || warn "$bad secret-store complaint(s) in the log"
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Phases: preflight | debloat-scan | debloat | tcpip | install | provision | verify
Options:
  --target <serial>      adb device (default: the only one connected)
  --from <ip>            panel to copy the house profile from (provision)
  --name <text>          the new panel's name
  --dashboard <url>      its Home Assistant dashboard
  --satellite <entity>   Voice Satellite entity (default: from --name)
  --hostname <text>      network hostname (default: from --name)
  --apk <path>           APK to install (default: the last release build)
  --apply                actually do the destructive part (debloat), or restart (verify)
Environment:
  KS_REMOTE_PW           admin password; else read from ~/Desktop/ks-remote-pw.txt
  KS_DEBLOAT_LIST        candidate file (default ./debloat-candidates.txt)
EOF
}

phase=${1:-}; shift || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --target) TARGET=$2; shift 2;;
    --from) SOURCE=$2; shift 2;;
    --name) NAME=$2; shift 2;;
    --dashboard) DASHBOARD=$2; shift 2;;
    --satellite) SATELLITE=$2; shift 2;;
    --hostname) HOSTNAME=$2; shift 2;;
    --apk) APK=$2; shift 2;;
    --apply|--restart) APPLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done

case "$phase" in
  preflight) phase_preflight;;
  debloat-scan) phase_debloat_scan;;
  debloat) phase_debloat;;
  tcpip) phase_tcpip;;
  install) phase_install;;
  provision) phase_provision;;
  verify) phase_verify;;
  *) usage; exit 1;;
esac
