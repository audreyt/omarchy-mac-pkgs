#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/omarchy-hw-apple-silicon"
export PATH="$work/bin:$PATH"
export OMARCHY_MAC_TOUCHID_PAM=$work/pam
mkdir "$OMARCHY_MAC_TOUCHID_PAM"
helper=$ROOT/lib/touchid-sddm

python3 -I "$helper" enable
[[ -z $(ls -A "$OMARCHY_MAC_TOUCHID_PAM") ]] || fail 'no SDDM means no PAM changes'
cat >"$work/original" <<'PAM'
#%PAM-1.0
auth include system-login
-auth optional pam_gnome_keyring.so
account include system-login
password include system-login
session include system-login
PAM
cp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
cat >"$OMARCHY_MAC_TOUCHID_PAM/system-login" <<'PAM'
auth required pam_shells.so
auth requisite pam_nologin.so
auth include system-auth
account required pam_access.so
PAM
cat >"$OMARCHY_MAC_TOUCHID_PAM/system-auth" <<'PAM'
auth required pam_faillock.so preauth
-auth [success=2 default=ignore] pam_systemd_home.so
auth [success=1 default=bad] pam_unix.so try_first_pass nullok
auth [default=die] pam_faillock.so authfail
auth optional pam_permit.so
auth required pam_env.so
auth required pam_faillock.so authsucc
PAM
python3 -I "$helper" enable
cp "$OMARCHY_MAC_TOUCHID_PAM/sddm" "$work/enabled"
python3 -I "$helper" enable
cmp "$work/enabled" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'enabling twice changes nothing'
python3 -I "$helper" disable
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling restores the exact original'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'the owned include is removed'
python3 -I "$helper" disable
pass 'SDDM enablement is optional, idempotent and reversible'

sed 's/$/\r/' "$work/original" >"$work/crlf"
cp "$work/crlf" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
python3 -I "$helper" enable
python3 -I "$helper" disable
cmp "$work/crlf" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling must preserve original line endings'
cp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
pass 'SDDM removal preserves the original line endings'

cp "$OMARCHY_MAC_TOUCHID_PAM/system-login" "$work/system-login"
printf 'auth required pam_deny.so\n' >>"$OMARCHY_MAC_TOUCHID_PAM/system-login"
! python3 -I "$helper" enable 2>"$work/error" || fail 'an inherited mandatory auth rule must not be bypassed'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'inherited policy refusal changed SDDM'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'inherited policy refusal installed a policy'
cp "$work/system-login" "$OMARCHY_MAC_TOUCHID_PAM/system-login"
cp "$OMARCHY_MAC_TOUCHID_PAM/system-auth" "$work/system-auth"
printf 'auth required pam_deny.so\n' >>"$OMARCHY_MAC_TOUCHID_PAM/system-auth"
! python3 -I "$helper" enable 2>"$work/error" || fail 'a custom system-auth rule must not be bypassed'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'custom system-auth refusal changed SDDM'
cp "$work/system-auth" "$OMARCHY_MAC_TOUCHID_PAM/system-auth"
pass 'inherited authentication requirements are preserved'

printf 'auth required pam_deny.so\n' >>"$OMARCHY_MAC_TOUCHID_PAM/sddm"
cp "$OMARCHY_MAC_TOUCHID_PAM/sddm" "$work/custom"
! python3 -I "$helper" enable 2>"$work/error" || fail 'custom auth rules must be preserved'
cmp "$work/custom" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'a refusal modified custom PAM'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'a refusal installed a policy'
rm "$OMARCHY_MAC_TOUCHID_PAM/sddm"
ln -s "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
! python3 -I "$helper" enable 2>"$work/error" || fail 'a symlink must be refused'
rm "$OMARCHY_MAC_TOUCHID_PAM/sddm"
cp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
printf 'administrator policy\n' >"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid"
! python3 -I "$helper" enable 2>"$work/error" || fail 'an administrator policy must be preserved'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'a refusal enabled custom policy'
pass 'custom and symlinked PAM files are refused before writes'

# Exercise the generated control flow with libpam, substituting only each
# authentication provider's result, not PAM's include/required/sufficient rules.
python3 -I - "$helper" "$work" <<'PY'
import ctypes
import ctypes.util
from pathlib import Path
import runpy
import sys

helper, root = Path(sys.argv[1]), Path(sys.argv[2]) / "dispatch"
root.mkdir()
policy = runpy.run_path(str(helper))["POLICY"]
library = ctypes.util.find_library("pam")
if library is None:
    raise RuntimeError("libpam is required for the PAM dispatch test")
pam = ctypes.CDLL(library)
pointer = ctypes.c_void_p

class Conversation(ctypes.Structure):
    _fields_ = [("function", pointer), ("data", pointer)]

pam.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                 ctypes.POINTER(Conversation), ctypes.c_char_p,
                                 ctypes.POINTER(pointer)]
pam.pam_authenticate.argtypes = [pointer, ctypes.c_int]
pam.pam_acct_mgmt.argtypes = [pointer, ctypes.c_int]
pam.pam_end.argtypes = [pointer, ctypes.c_int]
for fingerprint, password, shell, nologin, lockout, account, success in (
    (True, False, True, True, True, True, True),
    (False, True, True, True, True, True, True),
    (False, False, True, True, True, True, False),
    (True, True, False, True, True, True, False),
    (True, True, True, False, True, True, False),
    (True, True, True, True, False, True, False),
    (True, True, True, True, True, False, False),
):
    current = policy
    for module, result, arguments in (
        ("pam_shells.so", shell, ""),
        ("pam_nologin.so", nologin, ""),
        ("pam_faillock.so", lockout, " preauth"),
        ("pam_fprintd.so", fingerprint, " max-tries=3 timeout=10"),
    ):
        current = current.replace(module + arguments,
                                  "pam_permit.so" if result else "pam_deny.so")
    (root / "omarchy-mac-touchid").write_text(current)
    (root / "sddm").write_text(
        "auth include omarchy-mac-touchid\n"
        "auth required " + ("pam_permit.so" if password else "pam_deny.so") + "\n"
        "account required " + ("pam_permit.so" if account else "pam_deny.so") + "\n")
    handle = pointer()
    conversation = Conversation()
    result = pam.pam_start_confdir(b"sddm", b"fixture-user",
                                  ctypes.byref(conversation), str(root).encode(),
                                  ctypes.byref(handle))
    if result != 0:
        raise RuntimeError(f"pam_start_confdir: {result}")
    try:
        result = pam.pam_authenticate(handle, 0)
        if result == 0:
            result = pam.pam_acct_mgmt(handle, 0)
        assert (result == 0) == success, (
            fingerprint, password, shell, nologin, lockout, account, result)
    finally:
        pam.pam_end(handle, result)
print("ok - real PAM keeps password fallback and rejects shell, nologin, lockout and account failures")
PY
