#!/usr/bin/env bash
# idle-power-probe.sh — compare laptop idle power behaviour across OSes.
# Run on EACH OS while the machine sits IDLE at the SAME screen brightness.
# Needs sudo for a few root-only counters (energy + pmc_core); you'll be asked once.
#
#   chmod +x idle-power-probe.sh
#   ./idle-power-probe.sh
#
# It prints a report AND saves it next to the script so you can send it back.

set -u
ts=$(date +%Y%m%d-%H%M%S)
out="idle-probe-$(uname -n)-${ts}.txt"

# warm sudo so the timed measurements aren't interrupted by a password prompt
sudo -v 2>/dev/null

{
echo "######## idle-power-probe  $(date)  ########"
echo "host:   $(uname -n)"
echo "kernel: $(uname -r)"
echo "os:     $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
echo "cpu:    $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
echo

echo "== screen brightness (normalise this between OSes!) =="
for b in /sys/class/backlight/*/; do
  [ -e "$b/brightness" ] || continue
  cur=$(cat "$b/brightness"); max=$(cat "$b/max_brightness")
  awk -v n="$(basename "$b")" -v c="$cur" -v m="$max" \
    'BEGIN{printf "  %-16s %d/%d (%.0f%%)\n", n, c, m, 100*c/m}'
done
echo

echo "== cpuidle states  (native C6/C8/C10 ? or only C*_ACPI ?) =="
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
  [ -e "$s/name" ] || continue
  printf "  %-10s latency=%-6s residency=%s\n" \
    "$(cat "$s/name")" "$(cat "$s/latency" 2>/dev/null)" "$(cat "$s/residency" 2>/dev/null)"
done
echo "  driver: $(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)"
echo "  intel_idle.max_cstate=$(cat /sys/module/intel_idle/parameters/max_cstate 2>/dev/null)"
echo "  cmdline: $(cat /proc/cmdline)"
echo

echo "== RAPL package power over 5s (SoC only, screen-independent) =="
rapl=/sys/class/powercap/intel-rapl:0/energy_uj
if sudo test -r "$rapl"; then
  e1=$(sudo cat "$rapl"); sleep 5; e2=$(sudo cat "$rapl")
  awk -v a="$e1" -v b="$e2" 'BEGIN{printf "  package: %.2f W\n",(b-a)/5/1e6}'
else
  echo "  (intel-rapl not readable)"
fi
echo

echo "== S0ix / deep platform idle over 5s (0 = NOT entering it) =="
s0=/sys/kernel/debug/pmc_core/slp_s0_residency_usec
if sudo test -r "$s0"; then
  x1=$(sudo cat "$s0"); sleep 5; x2=$(sudo cat "$s0")
  echo "  slp_s0 delta: $((x2 - x1)) us / 5000000"
else
  echo "  (pmc_core not available)"
fi
echo "  -- package C-state residencies --"
sudo cat /sys/kernel/debug/pmc_core/package_cstate_show 2>/dev/null | sed 's/^/  /'
echo

echo "== C-state residency over 8s (is the CPU actually staying deep?) =="
snap(){ cat /sys/devices/system/cpu/cpu*/cpuidle/state"$1"/time 2>/dev/null | awk '{s+=$1}END{print s+0}'; }
ns=$(ls -d /sys/devices/system/cpu/cpu0/cpuidle/state*/ 2>/dev/null | wc -l)
ncpu=$(nproc)
declare -a A; for ((i=0;i<ns;i++)); do A[i]=$(snap "$i"); done
sleep 8
budget=$((8*ncpu*1000000))
for ((i=0;i<ns;i++)); do
  nm=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state"$i"/name 2>/dev/null)
  d=$(( $(snap "$i") - ${A[i]} ))
  awk -v nm="$nm" -v d="$d" -v bg="$budget" \
    'BEGIN{printf "  %-10s %5.1f%%\n", nm, 100*d/bg}'
done
echo

echo "== idle battery draw (instantaneous) =="
for bat in /sys/class/power_supply/BAT*; do
  [ -e "$bat/voltage_now" ] || continue
  v=$(cat "$bat/voltage_now")
  if [ -r "$bat/power_now" ]; then
    awk -v p="$(cat "$bat/power_now")" 'BEGIN{printf "  %.2f W\n", p/1e6}'
  elif [ -r "$bat/current_now" ]; then
    awk -v c="$(cat "$bat/current_now")" -v v="$v" 'BEGIN{printf "  %.2f W\n", c*v/1e12}'
  fi
done
echo

echo "== radios / ASPM =="
echo "  pcie_aspm policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
for w in /sys/class/net/wl*; do
  [ -e "$w" ] || continue
  echo "  $(basename "$w") power_save: $(iw dev "$(basename "$w")" get power_save 2>/dev/null | awk '{print $NF}')"
done
echo "  bluetooth: $(rfkill list bluetooth 2>/dev/null | awk -F: '/Soft blocked/{print "soft="$2} /Hard blocked/{print "hard="$2}' | tr '\n' ' ')"
echo
echo "######## end ########"
} 2>&1 | tee "$out"

echo
echo ">>> saved to: $(pwd)/$out  — send me this file."
