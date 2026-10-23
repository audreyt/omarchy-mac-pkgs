#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Nothing loads the Secure Enclave driver until the owner agrees. Before that,
# the boot-time status says whether Touch ID can be set up; the fingerprint
# setup's enable-fingerprint asks, then touchid-enable turns it on.
"$ROOT/install" "$work/root"
units=$work/root/usr/lib/systemd/system
for name in status load; do
  [[ -f $units/omarchy-mac-touchid-$name.service && -L $units/multi-user.target.wants/omarchy-mac-touchid-$name.service &&
    $(readlink "$units/multi-user.target.wants/omarchy-mac-touchid-$name.service") == "../omarchy-mac-touchid-$name.service" ]] ||
    fail "the $name unit is staged and pulled in at boot without enabling"
done
grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/touchid-status' "$units/omarchy-mac-touchid-status.service" &&
  grep -Fxq 'Before=display-manager.service fprintd.service' "$units/omarchy-mac-touchid-status.service" ||
  fail 'the status is recorded before the greeter or fprintd look for a reader'
load=$units/omarchy-mac-touchid-load.service
grep -Fxq 'ConditionPathExists=/etc/omarchy-mac/touchid-on' "$load" && grep -Fxq 'ExecStart=/usr/bin/modprobe apple-sep' "$load" &&
  grep -Fxq 'After=dev-disk-by\x2dpartlabel-iBootSystemContainer.device local-fs.target' "$load" ||
  fail "the driver loads at boot only on the owner's record, after the iBoot System Container's link it opens"
for name in enable-fingerprint disable-fingerprint; do
  [[ -x $work/root/usr/lib/omarchy/mac/$name ]] || fail "the $name entrypoint is staged for omarchy-lifecycle-dispatch"
done
[[ ! -e $work/root/etc/omarchy-mac/touchid-on ]] && ! grep -rqs 'apple-sep' "$work/root/etc" "$work/root/usr/lib/modules-load.d" ||
  fail 'the package itself never turns Touch ID on'
pass 'the status and load units and the enable and disable entrypoints are staged, and nothing turns Touch ID on'

fixture=$work/fixture
tree=$fixture/tree
mkdir -p "$fixture/bin" "$fixture/extractors"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/omarchy-hw-apple-silicon"
# The stub keeps the driver options it was loaded with, as modprobe reads them.
printf '#!/bin/sh\necho modprobe "$@" >>"%s"\ncp "%s" "%s" 2>/dev/null\n[ -e "%s" ] && exit 1\nmkdir -p "%s"\ntouch "%s" "%s"\n' \
  "$fixture/calls" "$fixture/etc/modprobe.conf" "$fixture/options-at-load" "$fixture/modprobe-fails" \
  "$fixture/module" "$fixture/sep-bio" "$fixture/keybag" >"$fixture/bin/modprobe"
printf '#!/bin/sh\necho systemctl "$@" >>"%s"\n[ "$1" = start ] && printf "%%s\\n" "$(cat "%s")" >"%s"\nexit 0\n' \
  "$fixture/calls" "$fixture/activation" "$fixture/run/touchid" >"$fixture/bin/systemctl"
printf '#!/bin/sh\n[ -e "%s" ] || echo /usr/lib/omarchy/mac/enable-fingerprint\n' "$fixture/no-hook" >"$fixture/bin/omarchy-lifecycle-dispatch"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/sleep"
printf '#!/bin/sh\necho calibration >>"%s"\nprintf calibration >"$2"\n' "$fixture/calls" >"$fixture/extractors/extract-mesa-calibration"
printf '#!/bin/sh\necho root-key >>"%s"\nprintf key >"$2"\n' "$fixture/calls" >"$fixture/extractors/extract-sensor-root-key"
chmod +x "$fixture/bin/"* "$fixture/extractors/"*

# A device tree: the machine's compatible list, a sensor node, and the identity.
machine() {
  rm -rf "$tree" "$fixture/firmware" "$fixture/run" "$fixture/etc" "$fixture/sep-bio" "$fixture/keybag" "$fixture/calls" "$fixture/no-hook" "$fixture/options-at-load" "$fixture/module" \
    "$fixture/esp" "$fixture/keys"
  mkdir -p "$tree/soc/spi@39b108000/fingerprint@0" "$tree/chosen" "$fixture/firmware" "$fixture/run"
  printf '%s\0' "$@" >"$tree/compatible"
  printf 'apple,mesa-fingerprint\0' >"$tree/soc/spi@39b108000/fingerprint@0/compatible"
  printf 'okay\0' >"$tree/soc/spi@39b108000/fingerprint@0/status"
  printf 'uuid' >"$tree/chosen/apfs-preboot-uuid"
  touch "$fixture/calls"
}
neo() {
  machine apple,j700 apple,t8140 apple,arm-platform
  printf 'apple/mesacal-j700.bin\0' >"$tree/soc/spi@39b108000/fingerprint@0/firmware-name"
  mkdir -p "$fixture/firmware/vendor/apple"
  printf sealed >"$fixture/firmware/vendor/apple/mesacal-j700.bin"
}
run() {
  PATH="$fixture/bin:$PATH" OMARCHY_MAC_TOUCHID_TREE=$tree OMARCHY_MAC_TOUCHID_FIRMWARE=$fixture/firmware \
    OMARCHY_MAC_TOUCHID_EXTRACTORS=$fixture/extractors OMARCHY_MAC_TOUCHID_AGREED=$fixture/etc/touchid-on \
    OMARCHY_MAC_TOUCHID_OPTIONS=$fixture/etc/modprobe.conf OMARCHY_MAC_TOUCHID_MODULE=$fixture/module \
    OMARCHY_MAC_TOUCHID_STATUS=$fixture/run/touchid OMARCHY_MAC_TOUCHID_HELPERS=$ROOT/lib \
    OMARCHY_MAC_TOUCHID_NODE=$fixture/sep-bio OMARCHY_MAC_TOUCHID_KEYBAG=$fixture/keybag \
    OMARCHY_MAC_TOUCHID_ESP=$fixture/esp OMARCHY_MAC_TOUCHID_KEYS=$fixture/keys OMARCHY_MAC_SNAPSHOT_MARKER=$fixture/run/snapshot-boot \
    OMARCHY_MAC_TOUCHID_PYTHON=${python:-sh} "$ROOT/lib/$1" "${@:2}"
}
eligibility() {
  run touchid-eligibility
}

machine apple,j414c apple,t6021 apple,arm-platform
[[ $(eligibility) == "available" ]] || fail 'an M2 Max with a sensor, an identity and an extractor is available' "$(eligibility)"
python=no-such-python
[[ $(eligibility) == "unsupported:no-calibration" ]] || fail 'without Python the extractor cannot run, so nothing is offered'
unset python
rm -rf "$tree/soc"
[[ $(eligibility) == "none" ]] || fail 'a Mac with no sensor node has no Touch ID'
machine apple,j414c apple,t6021 apple,arm-platform
printf 'disabled\0' >"$tree/soc/spi@39b108000/fingerprint@0/status"
[[ $(eligibility) == "none" ]] || fail 'a disabled sensor node is no Touch ID'
machine apple,j314s apple,t6000 apple,arm-platform
[[ $(eligibility) == "unsupported:m1-family" ]] || fail 'M1-family Macs wait for their xART guard path'
machine apple,j504 apple,t8122 apple,arm-platform
[[ $(eligibility) == "unsupported:board" ]] || fail 'a T8122 board whose wiring the driver has not read is unsupported'
machine apple,j613 apple,t8122 apple,arm-platform
[[ $(eligibility) == "available" ]] || fail 'the M3 Air J613 is available'
rm "$tree/chosen/apfs-preboot-uuid"
[[ $(eligibility) == "unsupported:no-os-identity" ]] || fail 'without the forwarded identity there is no lane for Linux'
neo
rm "$fixture/firmware/vendor/apple/mesacal-j700.bin"
[[ $(eligibility) == "unsupported:no-calibration" ]] ||
  fail "the Neo's calibration must be the sealed one its installer wrote, never a fresh carve"
neo
[[ $(eligibility) == "available" ]] || fail "a Neo with its installer's calibration and a root-key extractor is available"
mv "$fixture/extractors/extract-sensor-root-key" "$fixture/extractors/away"
[[ $(eligibility) == "unsupported:no-root-key" ]] || fail 'a Neo without its root key or a way to rebuild it is unsupported'
mkdir -p "$fixture/keys"
printf staged >"$fixture/keys/msrk-j700.bin"
[[ $(eligibility) == "available" ]] || fail "a Neo whose installer staged its sensor key needs no extractor"
mv "$fixture/extractors/away" "$fixture/extractors/extract-sensor-root-key"
pass 'only a Mac whose setup can finish is available'

# At boot the status says so for the detector, and never loads the driver.
machine apple,j414c apple,t6021 apple,arm-platform
run touchid-status
[[ $(<"$fixture/run/touchid") == "available" && $(stat -c %a "$fixture/run/touchid") == 644 ]] ||
  fail 'an available Mac records available, readable by the session user'
[[ ! -s $fixture/calls ]] || fail 'recording the status loads and carves nothing' "$(<"$fixture/calls")"
touch "$fixture/keybag"
run touchid-status
[[ $(<"$fixture/run/touchid") == "available" && ! -s $fixture/calls && ! -e $fixture/etc/touchid-on ]] ||
  fail 'a keybag from an earlier load is not agreement: the owner is asked like anyone else'
touch "$fixture/no-hook"
run touchid-status
[[ $(<"$fixture/run/touchid") == "unsupported:runtime" ]] ||
  fail "an Omarchy that can't ask first is offered nothing, so the one invitation is not spent"
machine apple,j314s apple,t6000 apple,arm-platform
run touchid-status
[[ $(<"$fixture/run/touchid") == "unsupported:m1-family" ]] || fail 'an unsupported Mac records why'
machine apple,j414c apple,t6021 apple,arm-platform
rm -rf "$tree/soc"
run touchid-status
[[ ! -e $fixture/run/touchid ]] || fail 'a Mac with no sensor records nothing'
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
run touchid-status
[[ ! -e $fixture/run/touchid && ! -s $fixture/calls ]] || fail 'once Touch ID is on, the activation records the status'
# The installer stages the Neo's sensor key on the ESP; the status moves it to
# a root-only place on the root, whether or not Touch ID is on.
for agreed in no yes; do
  neo
  mv "$fixture/extractors/extract-sensor-root-key" "$fixture/extractors/away"
  mkdir -p "$fixture/esp/vendorfw/touchid" "$fixture/etc"
  printf staged >"$fixture/esp/vendorfw/touchid/msrk-j700.bin"
  # vfat mounted umask=0077 shows its files as 0700, and cp keeps that.
  chmod 0700 "$fixture/esp/vendorfw/touchid/msrk-j700.bin"
  [[ $agreed == no ]] || touch "$fixture/etc/touchid-on"
  run touchid-status
  [[ $(<"$fixture/keys/msrk-j700.bin") == staged && $(stat -c %a "$fixture/keys/msrk-j700.bin") == 600 &&
    $(stat -c %a "$fixture/keys") == 700 && ! -e $fixture/esp/vendorfw/touchid && -d $fixture/esp/vendorfw ]] ||
    fail "the installer's sensor key moves off the ESP to a root-only file (agreed: $agreed)" "$(ls -lR "$fixture/esp" "$fixture/keys" 2>&1)"
  [[ $agreed == yes || $(<"$fixture/run/touchid") == "available" ]] || fail 'a Neo with its staged key and no extractor is available'
  [[ ! -e $fixture/firmware/updates/apple/msrk-j700.bin && ! -s $fixture/calls ]] || fail 'moving the key installs and loads nothing'
  mv "$fixture/extractors/away" "$fixture/extractors/extract-sensor-root-key"
done
neo
mkdir -p "$fixture/esp/vendorfw/touchid" "$fixture/keys"
printf new >"$fixture/esp/vendorfw/touchid/msrk-j700.bin"
printf old >"$fixture/keys/msrk-j700.bin"
run touchid-status
[[ $(<"$fixture/keys/msrk-j700.bin") == new && ! -e $fixture/keys/msrk-j700.bin.new ]] || fail 'a newer staged key replaces the one kept'
neo
mkdir -p "$fixture/esp/vendorfw/touchid"
printf staged >"$fixture/esp/vendorfw/touchid/msrk-j700.bin"
touch "$fixture/keys"
run touchid-status 2>/dev/null
[[ -f $fixture/esp/vendorfw/touchid/msrk-j700.bin && $(<"$fixture/esp/vendorfw/touchid/msrk-j700.bin") == staged && -f $fixture/keys ]] ||
  fail "a key that can't be kept on the root stays on the ESP"
rm "$fixture/keys"
: >"$fixture/esp/vendorfw/touchid/msrk-j700.bin"
run touchid-status
[[ -e $fixture/esp/vendorfw/touchid/msrk-j700.bin && ! -e $fixture/keys/msrk-j700.bin ]] ||
  fail 'an empty staged key, an interrupted write, is left where it is'
printf staged >"$fixture/esp/vendorfw/touchid/msrk-j700.bin"
touch "$fixture/run/snapshot-boot"
run touchid-status
[[ -s $fixture/esp/vendorfw/touchid/msrk-j700.bin && ! -e $fixture/keys/msrk-j700.bin ]] ||
  fail "a snapshot boot, whose root is lost at the next boot, leaves the staged key on the ESP"
rm "$fixture/run/snapshot-boot"
pass 'the boot status records available or why not, and never turns Touch ID on'

# Turning it on: carve what is missing, record the agreement, load now, and
# succeed only once the activation says Touch ID can enrol and match.
machine apple,j414c apple,t6021 apple,arm-platform
echo ready >"$fixture/activation"
out=$(run touchid-enable 2>&1) || fail 'an available Mac whose activation reads ready turns on' "$out"
[[ $(<"$fixture/firmware/updates/apple/mesa_calibration.bin") == "calibration" ]] ||
  fail 'the calibration is carved into the updates firmware directory under the default name'
[[ -f $fixture/etc/touchid-on && $(stat -c %a "$fixture/etc/touchid-on") == 644 ]] || fail "the owner's agreement is recorded"
grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/options-at-load" &&
  [[ $(stat -c %a "$fixture/etc/modprobe.conf") == 644 ]] ||
  fail "the driver is loaded with the options that let it write, which a read-only default needs"
[[ $(<"$fixture/calls") == $'calibration\nmodprobe apple-sep\nsystemctl start omarchy-mac-touchid-activate.service\nsystemctl try-restart fprintd.service' ]] ||
  fail 'it carves, loads the driver, waits for the activation, then restarts a running fprintd' "$(<"$fixture/calls")"
[[ $out == *"Touch ID is on."* ]] || fail 'it says so' "$out"
neo
run touchid-enable >/dev/null 2>&1 || fail 'a Neo turns on'
[[ $(stat -c %a "$fixture/firmware/updates/apple/msrk-j700.bin") == 600 ]] || fail "the Neo's root key is root-only"
grep -Fxq root-key "$fixture/calls" || fail 'without a staged key the Neo uses the extractor'
neo
mkdir -p "$fixture/keys"
printf staged >"$fixture/keys/msrk-j700.bin"
run touchid-enable >/dev/null 2>&1 || fail "a Neo turns on with its installer's key"
[[ $(<"$fixture/firmware/updates/apple/msrk-j700.bin") == staged && $(stat -c %a "$fixture/firmware/updates/apple/msrk-j700.bin") == 600 ]] &&
  ! grep -Fxq root-key "$fixture/calls" && [[ -f $fixture/keys/msrk-j700.bin ]] ||
  fail "the installer's key is installed root-only, without the extractor, and the staged copy stays" "$(<"$fixture/calls")"
neo
printf '#!/bin/sh\nprintf partial >"$2"\nexit 1\n' >"$fixture/extractors/extract-sensor-root-key"
! run touchid-enable >/dev/null 2>&1 && [[ ! -e $fixture/firmware/updates/apple/msrk-j700.bin && ! -e $fixture/firmware/updates/apple/msrk-j700.bin.new ]] ||
  fail 'a sensor key read only partly is never installed under its name'
printf '#!/bin/sh\necho root-key >>"%s"\nprintf key >"$2"\n' "$fixture/calls" >"$fixture/extractors/extract-sensor-root-key"
! grep -Fxq calibration "$fixture/calls" || fail "the Neo's sealed calibration is kept, never carved again"
machine apple,j414c apple,t6021 apple,arm-platform
echo not-ready >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ $out == *"did not become ready (not-ready)"* ]] && ! grep -q try-restart "$fixture/calls" ||
  fail 'an activation that does not reach ready fails, says what it read, and leaves fprintd alone' "$out"
[[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf && $out == *"restart before trying again"* ]] ||
  fail 'a Touch ID that never became ready takes the agreement back, so it does not load at every boot' "$out"
# A retry in the same boot after an ordinary failure: the driver this script
# loaded is not one loaded without the options.
! out=$(run touchid-enable 2>&1) && [[ -d $fixture/module && ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf ]] ||
  fail 'a retry after a failure in the same boot takes the agreement back again' "$out; $(ls -a "$fixture/etc" "$fixture/run" "$fixture/module" 2>&1 | tr '\n' ' ')"
echo ready >"$fixture/activation"
machine apple,j414c apple,t6021 apple,arm-platform
printf '#!/bin/sh\nexit 1\n' >"$fixture/extractors/extract-mesa-calibration"
! run touchid-enable >/dev/null 2>&1 && [[ ! -e $fixture/etc/touchid-on ]] && ! grep -q modprobe "$fixture/calls" ||
  fail 'a calibration that cannot be read turns nothing on'
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
! run touchid-enable >/dev/null 2>&1 && [[ -e $fixture/etc/touchid-on ]] ||
  fail "a failure keeps the record of an owner who agreed earlier"
printf '#!/bin/sh\necho calibration >>"%s"\nprintf calibration >"$2"\n' "$fixture/calls" >"$fixture/extractors/extract-mesa-calibration"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
echo not-ready >"$fixture/activation"
! run touchid-enable >/dev/null 2>&1 && [[ -e $fixture/etc/touchid-on ]] ||
  fail "a Touch ID that doesn't come up keeps the record of an owner who agreed earlier"
echo ready >"$fixture/activation"
machine apple,j414c apple,t6021 apple,arm-platform
touch "$fixture/modprobe-fails"
! out=$(run touchid-enable 2>&1) && [[ ! -e $fixture/etc/touchid-on && $out == *"driver did not load"* ]] &&
  ! grep -q 'systemctl start' "$fixture/calls" ||
  fail 'a driver that does not load takes the agreement back and starts nothing' "$out"
rm "$fixture/modprobe-fails"
# A driver already running, as a kernel that loads it read-only on every Mac
# leaves it, can't be told to write until it loads again: the agreement stands.
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/module"
echo not-ready >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ -e $fixture/etc/touchid-on && -e $fixture/etc/modprobe.conf && $out == *"turns on when this Mac restarts"* ]] ||
  fail 'a driver loaded before it could write keeps the agreement for the next boot' "$out"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/module"
echo ready >"$fixture/activation"
run touchid-enable >/dev/null 2>&1 || fail 'a driver already running that writes by default turns on now'
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/module" "$fixture/etc"
touch "$fixture/etc/modprobe.conf"
echo not-ready >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ $out == *"did not become ready (not-ready)"* && $out != *"turns on when this Mac restarts"* ]] ||
  fail 'a driver loaded with the options already in place that still fails says so, not that a restart will fix it' "$out"
echo ready >"$fixture/activation"
machine apple,j314s apple,t6000 apple,arm-platform
! run touchid-enable >/dev/null 2>&1 && [[ ! -e $fixture/etc/touchid-on ]] || fail 'an unsupported Mac is never turned on'
pass 'turning Touch ID on carves what is missing, records the agreement, and succeeds only when it is ready'

# The entrypoints use fixed paths; rewritten copies point them at the fixture.
entry=$work/entry
mkdir -p "$entry"
for name in enable-fingerprint disable-fingerprint; do
  sed -e "s|/run/omarchy-mac/touchid|$fixture/run/touchid|g" -e "s|/var/lib/aurora-sep-keybag.bin|$fixture/keybag|g" \
    -e "s|/usr/lib/omarchy-mac/touchid-enable|$fixture/bin/enable-stub|g" -e "s|/etc/omarchy-mac/touchid-on|$fixture/etc/touchid-on|g" \
    -e "s|/etc/modprobe.d/omarchy-mac-touchid.conf|$fixture/etc/modprobe.conf|g" -e "s|/var/lib/omarchy-mac/|$fixture/keys/|g" \
    -e "s|/proc/device-tree/compatible|$tree/compatible|g" "$ROOT/entrypoints/$name" >"$entry/$name"
  chmod +x "$entry/$name"
done
printf '#!/bin/sh\necho enable >>"%s"\nexit 0\n' "$fixture/calls" >"$fixture/bin/enable-stub"
chmod +x "$fixture/bin/enable-stub"
ask() {
  : >"$fixture/calls"
  printf '%s\n' "$2" >"$fixture/answer"
  echo "$1" >"$fixture/run/touchid"
  PATH="$fixture/bin:$PATH" "$entry/enable-fingerprint" <"$fixture/answer" >"$fixture/out" 2>&1
}
machine apple,j414c apple,t6021 apple,arm-platform
! ask available n && grep -q 'Touch ID stays off' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'an owner who says no turns nothing on' "$(<"$fixture/out")"
! ask available '' && [[ ! -s $fixture/calls ]] || fail 'no answer is no'
! PATH="$fixture/bin:$PATH" "$entry/enable-fingerprint" </dev/null >"$fixture/out" 2>&1 && [[ ! -s $fixture/calls ]] ||
  fail 'a closed terminal is no'
grep -q 'creates a key store' "$fixture/out" && grep -q 'anti-replay state' "$fixture/out" &&
  grep -q 'both systems update it' "$fixture/out" && grep -q 'With FileVault on' "$fixture/out" &&
  grep -q 'DFU' "$fixture/out" && grep -q 'With FileVault off' "$fixture/out" &&
  grep -q 'up anything on macOS you still need' "$fixture/out" && grep -q 'The key store stays' "$fixture/out" ||
  fail 'the owner is told about the shared state, the worst case for each FileVault setting and what stays' "$(<"$fixture/out")"
! grep -qE 'sensor key|earlier Touch ID setup' "$fixture/out" ||
  fail "a Mac that isn't a Neo, with no key store yet, is told nothing that applies only to others" "$(<"$fixture/out")"
ask available y && grep -Fxq enable "$fixture/calls" || fail 'an owner who says yes turns Touch ID on'
neo
touch "$fixture/keybag"
! ask available n && grep -q "sensor key, readable by root only" "$fixture/out" &&
  grep -q 'earlier Touch ID setup created' "$fixture/out" && ! grep -q 'creates a key store' "$fixture/out" ||
  fail 'a Neo with a key store is told what applies to it' "$(<"$fixture/out")"
! grep -q 'The installer kept' "$fixture/out" || fail "a Neo without the installer's key isn't told the installer kept one"
mkdir -p "$fixture/keys"
printf staged >"$fixture/keys/msrk-j700.bin"
! ask available n && grep -q "The installer kept a copy of this Mac's sensor key" "$fixture/out" &&
  grep -q 'It stays even if you say no' "$fixture/out" && ! grep -q 'Linux also keeps a copy' "$fixture/out" &&
  [[ -f $fixture/keys/msrk-j700.bin ]] ||
  fail "a Neo with its installer's key is told it is kept, and saying no leaves it" "$(<"$fixture/out")"
awk 'length > 80 { exit 1 }' "$fixture/out" || fail 'the prompt fits in 80 columns' "$(<"$fixture/out")"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
ask ready '' && [[ ! -s $fixture/calls && ! -s $fixture/out ]] || fail 'a Touch ID the owner already turned on asks nothing'
grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/etc/modprobe.conf" ||
  fail 'a Touch ID turned on before the driver options existed gets them'
rm "$fixture/etc/touchid-on"
! ask ready n && grep -q 'With FileVault on' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'a Touch ID turned off earlier this boot asks again before turning back on'
! ask unsupported:board '' && grep -q 'unsupported:board' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'an unsupported Mac is told why, and nothing turns on'
touch "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 && [[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf ]] &&
  grep -q 'key store for Linux stays' "$fixture/out" || fail "turning it off removes the owner's agreement and says the key store stays"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 || fail 'turning it off twice is fine'
touch "$fixture/keybag"
run touchid-status
[[ $(<"$fixture/run/touchid") == "available" && ! -s $fixture/calls ]] ||
  fail 'after turning it off, the next boot leaves it off and only offers it again'
pass 'enable-fingerprint asks before anything turns on, and turning it off lasts'

if command -v systemd-analyze >/dev/null; then
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon modprobe; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  for name in status load; do
    systemd-analyze --root="$work/root" verify --man=no "/usr/lib/systemd/system/omarchy-mac-touchid-$name.service" 2>"$work/verify" ||
      fail "systemd accepts the $name unit" "$(cat "$work/verify")"
  done
  pass 'systemd accepts the Touch ID status and load units'
fi
