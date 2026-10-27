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

for name in sddm system-login system-auth; do
  cp "$OMARCHY_MAC_TOUCHID_PAM/$name" "$work/case-original"
  for kind in AUTH Auth -AUTH --auth not-a-pam-type; do
    printf '%s required pam_deny.so\n' "$kind" >>"$OMARCHY_MAC_TOUCHID_PAM/$name"
    cp "$OMARCHY_MAC_TOUCHID_PAM/sddm" "$work/case-sddm"
    cp "$OMARCHY_MAC_TOUCHID_PAM/$name" "$work/case-source"
    ! python3 -I "$helper" enable 2>"$work/error" || fail 'case-variant authentication rules must be refused'
    cmp "$work/case-sddm" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'case-variant refusal changed SDDM'
    cmp "$work/case-source" "$OMARCHY_MAC_TOUCHID_PAM/$name" || fail 'case-variant refusal changed the source policy'
    [[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'case-variant refusal installed a policy'
    cp "$work/case-original" "$OMARCHY_MAC_TOUCHID_PAM/$name"
  done
done
pass 'case-variant authentication rules are refused without writes'

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

previous=$(python3 -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["PREVIOUS_POLICIES"][0], end="")' "$helper")
printf '%s\n' "$previous" >"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid"
printf '# omarchy-mac Touch ID\nauth include omarchy-mac-touchid\n' | cat - "$work/original" >"$OMARCHY_MAC_TOUCHID_PAM/sddm"
python3 -I "$helper" enable
current=$(python3 -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["POLICY"], end="")' "$helper")
[[ $(<"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid") == "$current" ]] || fail 'enabling replaces the previous owned policy'
python3 -I "$helper" disable
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling after an upgrade restores the original'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'the upgraded policy is removed'
printf '%s\n' "$previous" >"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid"
python3 -I "$helper" disable
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'a previous owned policy is removed on disable'
pass 'the previous owned policy is upgraded and removed'

# Exercise the generated control flow with libpam and the real empty-password
# helper through pam_exec, substituting only the keyring, fingerprint and
# password providers' results.
python3 -I - "$helper" "$work" "$ROOT/lib" <<'PY'
import ctypes
import ctypes.util
from pathlib import Path
import runpy
import sys

helper, work, lib = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
root = work / "dispatch"
root.mkdir()
policy = runpy.run_path(str(helper))["POLICY"]
library = ctypes.util.find_library("pam")
if library is None:
    raise RuntimeError("libpam is required for the PAM dispatch test")
pam = ctypes.CDLL(library)
libc = ctypes.CDLL(ctypes.util.find_library("c"))
libc.malloc.restype = ctypes.c_void_p
libc.strdup.restype = ctypes.c_void_p
libc.strdup.argtypes = [ctypes.c_char_p]
pointer = ctypes.c_void_p

class Message(ctypes.Structure):
    _fields_ = [("style", ctypes.c_int), ("text", ctypes.c_char_p)]

class Response(ctypes.Structure):
    _fields_ = [("text", pointer), ("code", ctypes.c_int)]

CONVERSE = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int,
                            ctypes.POINTER(ctypes.POINTER(Message)),
                            ctypes.POINTER(ctypes.POINTER(Response)), pointer)

class Conversation(ctypes.Structure):
    _fields_ = [("function", CONVERSE), ("data", pointer)]

pam.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                 ctypes.POINTER(Conversation), ctypes.c_char_p,
                                 ctypes.POINTER(pointer)]
pam.pam_authenticate.argtypes = [pointer, ctypes.c_int]
pam.pam_acct_mgmt.argtypes = [pointer, ctypes.c_int]
pam.pam_end.argtypes = [pointer, ctypes.c_int]

def script(name, body):
    path = work / name
    path.write_text("#!/bin/bash\n" + body)
    path.chmod(0o755)
    return path

record = work / "authfail-record"
# pam_exec passes no PATH, so point the real helper's platform check at the stub.
empty = script("empty-password", (lib / "touchid-pam-empty-password").read_text().removeprefix("#!/bin/bash\n")
               .replace("omarchy-hw-apple-silicon", str(work / "bin" / "omarchy-hw-apple-silicon")))
keyring = {True: script("keyring-unlocked", "exit 0\n"),
           False: script("keyring-locked", "exit 1\n")}
authfail = script("authfail", f"echo >>{record}\nexit 0\n")
check = script("password-check", "IFS= read -r -d '' typed || true\n"
               "if [[ $typed == secret ]]; then exit 0; else exit 1; fi\n")

def attempt(typed, unlocked, fingerprint, password=True, shell=True, nologin=True,
            lockout=True, account=True):
    current = policy.replace("/usr/lib/omarchy-mac/touchid-pam-empty-password", str(empty))
    current = current.replace("/usr/lib/omarchy-mac/touchid-pam-keyring-unlocked",
                              str(keyring[unlocked]))
    current = current.replace("pam_fprintd.so max-tries=3 timeout=5",
                              f"pam_debug.so auth={fingerprint}")
    current = current.replace("pam_faillock.so authfail", f"pam_exec.so {authfail}")
    for module, result in (("pam_shells.so", shell), ("pam_nologin.so", nologin),
                           ("pam_faillock.so preauth", lockout)):
        current = current.replace(module, "pam_permit.so" if result else "pam_deny.so")
    (root / "omarchy-mac-touchid").write_text(current)
    stack = (f"auth required pam_exec.so expose_authtok {check}\n" if password
             else "auth required pam_deny.so\n")
    (root / "sddm").write_text(
        "auth include omarchy-mac-touchid\n" + stack +
        "account required " + ("pam_permit.so" if account else "pam_deny.so") + "\n")
    record.unlink(missing_ok=True)
    prompts = []

    def converse(count, messages, responses, data):
        answers = ctypes.cast(libc.malloc(ctypes.sizeof(Response) * count),
                              ctypes.POINTER(Response))
        for index in range(count):
            message = messages[index].contents if count == 1 else messages[0][index]
            answers[index].code = 0
            answers[index].text = None
            if message.style == 1:
                prompts.append(message.text)
                answers[index].text = libc.strdup(typed.encode())
        responses[0] = answers
        return 0

    function = CONVERSE(converse)
    conversation = Conversation(function, None)
    handle = pointer()
    result = pam.pam_start_confdir(b"sddm", b"fixture-user", ctypes.byref(conversation),
                                  str(root).encode(), ctypes.byref(handle))
    if result != 0:
        raise RuntimeError(f"pam_start_confdir: {result}")
    try:
        result = pam.pam_authenticate(handle, 0)
        if result == 0:
            result = pam.pam_acct_mgmt(handle, 0)
    finally:
        pam.pam_end(handle, result)
    return result == 0, len(prompts), record.exists()

cases = (
    (dict(typed="", unlocked=True, fingerprint="success"), (True, 1, False)),
    (dict(typed="", unlocked=True, fingerprint="authinfo_unavail"), (False, 1, False)),
    (dict(typed="", unlocked=True, fingerprint="auth_err"), (False, 1, False)),
    (dict(typed="", unlocked=True, fingerprint="maxtries"), (False, 1, True)),
    (dict(typed="", unlocked=False, fingerprint="success"), (False, 1, False)),
    (dict(typed="", unlocked=True, fingerprint="authinfo_unavail", password=True), (False, 1, False)),
    (dict(typed="secret", unlocked=True, fingerprint="success", password=False), (False, 1, False)),
    (dict(typed="secret", unlocked=False, fingerprint="maxtries"), (True, 1, False)),
    (dict(typed="wrong", unlocked=True, fingerprint="success"), (False, 1, False)),
    (dict(typed="", unlocked=True, fingerprint="success", shell=False), (False, 0, False)),
    (dict(typed="", unlocked=True, fingerprint="success", nologin=False), (False, 0, False)),
    (dict(typed="", unlocked=True, fingerprint="success", lockout=False), (False, 0, False)),
    (dict(typed="secret", unlocked=True, fingerprint="success", lockout=False), (False, 0, False)),
    (dict(typed="", unlocked=True, fingerprint="success", account=False), (False, 1, False)),
)
for arguments, expected in cases:
    observed = attempt(**arguments)
    assert observed == expected, (arguments, expected, observed)
print("ok - real PAM sends empty passwords to Touch ID only with an unlocked keyring, sends typed passwords straight to the password stack with one prompt, and keeps shell, nologin, lockout and account checks")
PY

# The keyring check never starts a stopped keyring and accepts only an unlocked login collection.
python3 -I - "$ROOT/lib/touchid-pam-keyring-unlocked" "$work" <<'PY'
import os
from pathlib import Path
import pwd
import runpy
import socket
import subprocess
import sys

module = runpy.run_path(sys.argv[1])
unlocked = module["unlocked"]
runtime = Path(sys.argv[2]) / "runtime"
user = pwd.getpwuid(os.getuid())
bus = runtime / str(user.pw_uid) / "bus"

def fake(owner, locked, failure=None):
    calls = []

    def run(command, **options):
        calls.append(command)
        assert command[:2] == ["/usr/bin/setpriv", f"--reuid={user.pw_uid}"], command
        assert f"--address=unix:path={bus}" in command, command
        if failure:
            raise failure
        if "NameHasOwner" in command:
            return subprocess.CompletedProcess(command, 0, f"b {owner}\n", "")
        return subprocess.CompletedProcess(command, 0, f"b {locked}\n", "")
    return run, calls

run, calls = fake("true", "false")
assert not unlocked(user.pw_name, run, runtime) and not calls, "no user bus means locked"
bus.parent.mkdir(parents=True)
listener = socket.socket(socket.AF_UNIX)
listener.bind(str(bus))
assert unlocked(user.pw_name, run, runtime) and len(calls) == 2
run, calls = fake("false", "false")
assert not unlocked(user.pw_name, run, runtime) and len(calls) == 1, "a stopped keyring is never queried"
run, calls = fake("true", "true")
assert not unlocked(user.pw_name, run, runtime)
run, calls = fake("true", "false", subprocess.TimeoutExpired("busctl", 5))
assert not unlocked(user.pw_name, run, runtime)
assert not unlocked("no-such-user-omarchy-mac", run, runtime)
print("ok - the keyring check requires a running, unlocked login collection")
PY
