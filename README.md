# fw12powersave

Idle-power tuning for the **Framework Laptop 12** (13th-gen Intel, e.g. i5-1334U)
on **Arch / Omarchy + Hyprland**, distilled from an actual debugging session that
took idle draw from ~3.5 W down toward ~1.3–1.8 W.

> TL;DR: on this machine idle power is **not** a kernel / C-state problem. It's
> **screen-off-on-idle + S3 suspend + brightness**. This repo applies the two
> config changes that actually move the needle, and documents why.

## Proof it works

`powerstat` on a Framework 12 (i5-1334U, Omarchy/Hyprland), idle with screen off,
**after** applying this repo — full log in [`results/powerstat-after.txt`](results/powerstat-after.txt):

```
Summary:
System:   1.69 Watts on average with standard deviation 0.08
```

**~4 W → 1.69 W average**, below the GNOME/Fedora ~2 W reference that started the hunt.

---

## What it does

`./install.sh` makes exactly two changes:

1. **hypridle: turn the display fully OFF on idle.**
   The stock Omarchy hypridle launches an animated *screensaver* and never does
   `dpms off` — which is the worst case for power. With the screen on, the
   compositor scanning out to the panel pins the SoC package in shallow
   **PC2/PC3 (~2.95 W)**. The moment the display turns off, the package reaches
   **PC6/PC8 (~1.8 W)** *and* the backlight powers down. Installs a clean config:
   lock + `dpms off` at **90 s**, suspend at **10 min**, idle-inhibitors respected
   (so fullscreen *and* windowed video keep the screen on).

2. **S3 ("deep") suspend instead of s2idle.**
   s2idle on this box never reaches deep platform idle (`slp_s0_residency` stays
   **0**), so "suspend" drains noticeably. This BIOS *does* advertise S3
   (`ACPI: PM: (supports S0 S3 S4 S5)`), which truly powers the SoC down.
   Enabled via a `tmpfiles.d` rule that sets `/sys/power/mem_sleep` to `deep`
   at boot — bootloader-agnostic, no UKI/cmdline edit needed.

Both changes are backed up and fully reversible (`./uninstall.sh`).

---

## The findings (why these and not the usual advice)

A side-by-side probe against the *same silicon* running stock Fedora settled it:

| Metric | Omarchy (screen on) | Omarchy (screen off) | Fedora deep-idle |
|---|---|---|---|
| RAPL package | **2.95 W** | **1.81 W** | 1.66 W |
| Package C6 / C8 | 0% / 0% | **58% / 10%** | deep |
| cpuidle states | `C1/C2/C3_ACPI` | same | **same** |
| `slp_s0` (S0ix) | 0 | 0 | 0 |

Things that turned out to be **dead ends** (don't bother):

- **`intel_idle` native C6/C8/C10 / `intel_idle.no_acpi=1` / `max_cstate=10`.**
  This CPU exposes only `C1/C2/C3_ACPI` (firmware ACPI `_CST`, no native table) —
  and **stock Fedora shows the identical states.** It's normal for this Raptor
  Lake-U part, not a distro bug. The cores already reach deep hardware states
  despite the `C3` label (the package hits PC8). No kernel param changes this.
- **Swapping to the CachyOS kernel.** Tried it; idle behaviour was identical.
- **PCIe ASPM / runtime-PM tweaks.** Already fine; didn't move package power.

What **actually** matters: **screen off** (compositor stops pinning the package
shallow + backlight off) and **S3 suspend**. Plus brightness, which is the
biggest single knob — Fedora's "2 W" reference was at 6–8% brightness.

---

## Requirements

- Framework Laptop 12 (or similar 13th-gen Intel U-series) — check `/sys/power/mem_sleep`
  for `deep` to know if your BIOS supports S3.
- Hyprland + `hypridle`.
- systemd. `sudo` for the S3 `tmpfiles.d` rule.
- Best on Omarchy (uses `omarchy-system-lock`); falls back to `loginctl lock-session` otherwise.

## Install

```bash
git clone https://github.com/mechanicsunlocked/fw12powersave.git
cd fw12powersave
./install.sh
```

Tune the timeouts (seconds) if you like:

```bash
SCREENOFF_SEC=120 SUSPEND_SEC=900 ./install.sh
```

## ⚠️ Test S3 resume before relying on auto-suspend

S3 resume is solid on the tested FW12 BIOS, but Framework Intel laptops have had
deep-sleep quirks across gens. After installing, **test once manually**:

```bash
systemctl suspend     # screen/fans fully off
# press power button to wake -> confirm it resumes cleanly
```

If it hangs or wakes instantly, run `./uninstall.sh` (or just remove
`/etc/tmpfiles.d/fw12-s3-deep.conf`) and you're back on s2idle.

## What gets changed

| Path | Change |
|---|---|
| `~/.config/hypr/hypridle.conf` | replaced (timestamped backup kept) |
| `/etc/tmpfiles.d/fw12-s3-deep.conf` | created → sets `mem_sleep=deep` at boot |

## Verify it's working

```bash
# package power with screen off (let it idle past the timeout first):
e1=$(sudo cat /sys/class/powercap/intel-rapl:0/energy_uj); sleep 10; \
e2=$(sudo cat /sys/class/powercap/intel-rapl:0/energy_uj); \
awk -v a=$e1 -v b=$e2 'BEGIN{printf "%.2f W\n",(b-a)/10/1e6}'   # expect ~1.8 W

cat /sys/power/mem_sleep            # expect: s2idle [deep]
```

There's also `probe.sh` — the diagnostic script used in the investigation. Run it
on any OS to dump cpuidle states, package C-states, S0ix, RAPL and battery draw
for an apples-to-apples comparison.

## Uninstall

```bash
./uninstall.sh
```

Restores the previous hypridle config and removes the S3 rule (reverts to s2idle
on next boot; `echo s2idle | sudo tee /sys/power/mem_sleep` to revert immediately).

---

## License

MIT. No warranty — you're changing power/suspend behaviour on your own hardware.
