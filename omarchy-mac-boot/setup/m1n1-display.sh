# The M3 Airs' native display and GPU: m1n1 hands each to Linux only on its
# chosen.asahi,t8122-* switch in /etc/m1n1.conf, which update-m1n1 copies into
# boot.bin. An m1n1 without the display's opt-in gate black-screens these Macs.
omarchy-hw-apple-silicon || return 0
[[ ${OMARCHY_MAC_IMAGE_BUILD:-} != "1" ]] || return 0
# setup-boot clears the environment, so only a booted systemd tells the leaf it
# is not in a chroot (an image build's or an installer's).
[[ -d ${OMARCHY_SYSTEMD_RUN:-/run/systemd/system} ]] || return 0

(
  set -uo pipefail
  # The first m1n1-aurora that reserves the external DCP firmware only on its
  # own opt-in (omacom/m1n1#14, omarchy-pkgs#1564); 20-3 black-screens. Keep the pkgrel.
  m1n1_t8122_dcp_minimum=1.6.1.aurora20-4
  minimum_m1n1=${OMARCHY_M1N1_T8122_DCP_MINIMUM-$m1n1_t8122_dcp_minimum}
  compatible=${OMARCHY_DEVICE_TREE_COMPATIBLE:-/proc/device-tree/compatible}
  config=${OMARCHY_M1N1_CONF:-/etc/m1n1.conf}
  key=chosen.asahi,t8122-dcp
  # The GPU start and its power handoff: the boot loader's power model with this Mac's leakage fuses.
  gpu_keys=("chosen.asahi,t8122-gpu" "chosen.asahi,t8122-gpu-power-standin" "chosen.asahi,t8122-gpu-fuse-leakage")

  machine=
  [[ ! -r $compatible ]] || machine=$(tr '\0' '\n' <"$compatible")
  m1n1_display_has() { [[ $'\n'$machine$'\n' == *$'\n'"$1"$'\n'* ]]; }

  m1n1_display_has apple,t8122 || exit 0
  # The M3 Airs (J613, J615); the other T8122 Macs' displays are untested.
  m1n1_display_has apple,j613 || m1n1_display_has apple,j615 || exit 0
  if [[ -z $minimum_m1n1 ]]; then
    echo "m1n1-display: no m1n1-aurora with the T8122 display opt-in is known yet; leaving $config alone"
    exit 0
  fi
  # pacman -Q also answers for a package that only provides the name.
  name= installed=
  read -r name installed < <(pacman -Q m1n1-aurora 2>/dev/null) || true
  if [[ $name != "m1n1-aurora" || -z $installed ]]; then
    echo "m1n1-display: m1n1-aurora is not installed; leaving $config alone"
    exit 0
  fi
  # Fail closed: a comparison that cannot be made writes nothing.
  if ! order=$(vercmp "$installed" "$minimum_m1n1" 2>/dev/null) || [[ ! $order =~ ^-?[0-9]+$ ]]; then
    echo "m1n1-display: cannot compare m1n1-aurora $installed with $minimum_m1n1; leaving $config alone"
    exit 0
  fi
  if (( order < 0 )); then
    echo "m1n1-display: m1n1-aurora $installed predates the T8122 display opt-in ($minimum_m1n1); leaving $config alone"
    exit 0
  fi
  # A line the owner wrote, for either value, is theirs to keep.
  display=
  [[ ! -r $config ]] || display=$(sed -nE "s/^[[:space:]]*${key//./\\.}=([^[:space:]]*).*/\\1/p" "$config" | tail -n 1)
  wanted=()
  if [[ -z $display ]]; then
    wanted+=("$key")
    display=1
  fi
  # The GPU starts only beside the display handoff, and any GPU or native-profile line means the owner chose its setup.
  if [[ $display == "1" ]] && ! { [[ -r $config ]] && grep -Eq '^[[:space:]]*chosen\.asahi,(t8122-gpu|j61[35]-25g83)[^=]*=' "$config"; }; then
    wanted+=("${gpu_keys[@]}")
  fi
  (( ${#wanted[@]} > 0 )) || exit 0

  m1n1_display_unstaged() { echo "m1n1-display: could not stage $config; leaving it alone" >&2; exit 0; }
  staged=$(mktemp -d) || m1n1_display_unstaged
  trap 'rm -rf "$staged"' EXIT
  : >"$staged/new" || m1n1_display_unstaged
  if [[ -e $config ]]; then
    cp "$config" "$staged/original" && cp "$config" "$staged/new" || m1n1_display_unstaged
    # Keep a last line without its newline from swallowing ours.
    [[ ! -s $staged/new || $(tail -c 1 "$staged/new" | od -An -c | tr -d ' ') == '\n' ]] ||
      printf '\n' >>"$staged/new" || m1n1_display_unstaged
  fi
  {
    printf '# omarchy-mac-boot: the M3 Air native display and GPU. Set a line to 0 to keep m1n1 from handing it over.\n'
    printf '%s=1\n' "${wanted[@]}"
  } >>"$staged/new" || m1n1_display_unstaged

  # Put the original bytes back (install can unlink the file before copying).
  m1n1_display_restore() {
    if [[ -e $staged/original ]]; then
      sudo install -m 0644 "$staged/original" "$config"
    else
      sudo rm -f "$config"
    fi
  }
  m1n1_display_failed() {
    if m1n1_display_restore; then
      echo "m1n1-display: $1; $config is back as it was, and boot.bin is unchanged unless update-m1n1 failed after replacing it" >&2
    else
      echo "m1n1-display: $1, and $config could not be put back; the next update-m1n1 takes its new lines" >&2
    fi
    exit 0
  }
  sudo install -D -m 0644 "$staged/new" "$config" || m1n1_display_failed "could not write $config"
  # boot.bin only takes m1n1.conf when update-m1n1 builds it.
  sudo update-m1n1 || m1n1_display_failed "update-m1n1 failed"
  echo "m1n1-display: enabled ${wanted[*]} in $config"
)
