# NVIDIA Overlay Battery Patch v3

A lightweight Windows patch for laptops that extends the **NVIDIA App Performance Overlay** with battery telemetry and a more reliable GPU-temperature reading, while keeping NVIDIA's native fullscreen overlay, hotkey and rendering path.

The project was created around a **Microsoft Surface Laptop Studio 2** use case: NVIDIA's overlay already gives useful CPU/GPU telemetry in games, but it does not show the battery information that matters on a laptop, and on this device the native NVIDIA GPU-temperature metric could display **`0°C`** even though the GPU was present and usable.

The result is a compact top-center laptop HUD such as:

```text
CPU 16% 54°C | BAT 78% ↓14.6W 4:12 | GPU 8% 47°C
```

While charging:

```text
CPU 11% 52°C | BAT 63% ↑36.8W 0:51 | GPU 2% 46°C
```

> **Important:** This is an unofficial community project. It is not affiliated with, supported by, or endorsed by NVIDIA or Microsoft.

---

## Why this exists

NVIDIA's Performance Overlay is a very good base for a laptop HUD because it is already integrated into the NVIDIA App, can stay visible over games/fullscreen applications and can be toggled globally with:

```text
Alt + R
```

For a desktop PC, values such as FPS, clocks and GPU power may be enough. On a laptop, however, the questions are often different:

- How much battery is left?
- Is the laptop currently charging or discharging?
- How many watts are flowing into or out of the battery?
- Roughly how long will the laptop last at the current load?
- Roughly how long until the battery is full?
- How hot are CPU and GPU?
- Is the dedicated NVIDIA GPU actually awake, or is it power-gated by the hybrid graphics system?

This project keeps NVIDIA's native overlay and replaces the information that is not useful for this use case with laptop-specific telemetry.

The default patched metric set is:

```text
CPU utilization
CPU temperature
Battery status
GPU utilization
GPU temperature
```

CPU/GPU clocks, FPS, latency and other advanced values are intentionally omitted from the default layout.

---

## Surface Laptop Studio 2 GPU-temperature fix

### The problem

On the Surface Laptop Studio 2 used during development, NVIDIA's own Performance Overlay could show:

```text
GPU 0% 0°C
```

The `0°C` value is not a physically meaningful GPU temperature. Hybrid/Optimus laptops can completely power down the dedicated NVIDIA GPU while it is idle, and the temperature path used by NVIDIA's overlay does not always produce a useful value in that state or on every laptop/driver combination.

Instead of trusting `0°C`, v3 adds an independent GPU-temperature probe to the local provider.

### The fix

The provider probes the NVIDIA driver directly in this order:

```text
NVML
  ↓ if unavailable / no valid reading
nvidia-smi
  ↓ if unavailable / GPU exposes no temperature
OFF
```

The primary path uses NVIDIA Management Library (**NVML**) and calls the driver's GPU-temperature API directly. The fallback executes:

```text
nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits
```

The provider probes the GPU at most once every **5 seconds** so that temperature monitoring itself does not create unnecessary constant load.

The JavaScript patch then handles NVIDIA's `gpuTemp` metric as follows:

```text
valid provider temperature  -> show the real temperature
provider says OFF           -> show OFF instead of a fake 0°C
provider cannot determine   -> allow NVIDIA's native metric to continue
```

So an idle hybrid laptop can correctly show:

```text
GPU 0% OFF
```

and when the NVIDIA GPU wakes up it can change to, for example:

```text
GPU 42% 51°C
```

This workaround was added specifically because of the observed Surface Laptop Studio 2 behavior, but it can also help other Optimus/hybrid-GPU laptops where NVIDIA's overlay temperature is missing or reports `0°C`.

> If more than one NVIDIA GPU is installed, the current provider uses the highest valid temperature reported by the NVIDIA devices it sees.

---

## Battery telemetry

The battery provider reads Windows battery information locally and builds one compact string for NVIDIA's overlay.

Depending on what the laptop firmware and Windows expose, the BAT field can contain:

- battery percentage
- battery temperature
- charging/discharging state
- charge/discharge rate in watts
- estimated time until empty
- estimated time until full

Examples:

```text
BAT 78% ↓14.6W 4:12
BAT 63% ↑36.8W 0:51
BAT 100% AC
```

Meaning:

```text
↓14.6W  = battery is discharging at about 14.6 W
↑36.8W  = battery is charging at about 36.8 W
4:12     = estimated 4 h 12 min remaining
0:51     = estimated 51 min until full
AC       = external power detected but no usable charge-rate value is available
```

Battery rate is averaged across a short history to prevent the displayed wattage from jumping wildly every sample. The history is reset when the direction changes between charging and discharging.

Battery temperature is optional. Many Windows laptops do **not** expose a usable `BatteryTemperature` WMI class. In that case the patch simply omits battery temperature instead of inventing a value.

---

## How it works

The project deliberately avoids replacing NVIDIA's renderer.

The architecture is:

```text
Windows battery / power data
          │
          ▼
NvBatteryProvider.exe
          │
          ├── battery % / W / remaining time / optional battery temp
          └── GPU temp fallback through NVML / nvidia-smi
          │
          ▼
http://127.0.0.1:37921/status
          │
          ▼
patched NVIDIA OSC JavaScript
          │
          ▼
NVIDIA App Performance Overlay
          │
          ▼
Desktop / fullscreen game
```

NVIDIA still performs the actual overlay rendering. That means the existing NVIDIA behavior remains available, including the normal fullscreen/game integration and `Alt + R` toggle.

### Why the CPU-clock slot is reused

The patch does not try to add a completely new native metric type to NVIDIA's internal performance-monitoring stack.

Instead, the existing `cpuClock` metric slot is repurposed as:

```text
BAT
```

The patched custom set becomes:

```text
cpuUtil
cpuTemp
gpuUtil
gpuTemp
cpuClock -> BAT
```

For this laptop-focused layout, CPU clock frequency was intentionally considered less useful than battery state. Reusing an existing slot also keeps the patch smaller and avoids modifying NVIDIA DLLs.

The patch additionally forces:

```text
Layout:   Linear
Position: Top Center
```

---

# Installation

## Requirements

- Windows 11 / modern Windows 10
- NVIDIA App with the OSC frontend present
- NVIDIA Performance Overlay enabled
- administrator rights for installation/patching
- a supported NVIDIA OSC JavaScript layout

The current compatibility profile was developed against the NVIDIA bundle:

```text
main.deaee2ff72bfcecf.js
```

with clean-source SHA-256:

```text
60D68F2040C2B92CF97A13D83F81ACCDF4ABE7D681842D9D51ADEB99C9CAFED5
```

A different SHA-256 can still be patched if every structural anchor required by the profile is found **exactly once**.

## Install

1. Download the release ZIP.
2. Extract the ZIP completely.
3. Double-click **`Install.cmd`**.
4. Confirm the Windows UAC prompt.
5. Wait until **`INSTALLATION FERTIG`** is displayed.
6. If the NVIDIA statistics overlay is hidden, press **`Alt + R`** once.

An existing v1/v2 installation does **not** have to be removed first. v3 detects the old patch and, where possible, rebuilds v3 from the clean `.nvbo-original` backup created by the earlier version.

---

## Local status page

After installation, open:

```text
http://127.0.0.1:37921/status
```

Example:

```json
{
  "providerVersion": "3.0.0",
  "display": "BAT 78% ↓14.6W 4:12",
  "percent": 78.0,
  "watts": -14.6,
  "minutes": 252,
  "charging": false,
  "discharging": true,
  "pluggedIn": false,
  "gpuTempC": 47.0,
  "gpuState": "ACTIVE"
}
```

The HTTP server binds to:

```text
127.0.0.1:37921
```

only. It is not intentionally exposed to the LAN or Internet.

---

# Update resistance in v3

The NVIDIA App does not provide a public supported extension API for this overlay customization. NVIDIA updates can therefore replace the patched frontend.

v3 does **not** block NVIDIA updates. Instead, it watches for a new frontend, validates compatibility and safely reapplies the patch only when the new build still matches the expected structure.

The design principle is:

> **Automatically repair compatible NVIDIA updates and safely refuse incompatible ones.**

## 1. Active bundle detection

The patcher first reads NVIDIA's:

```text
C:\Program Files\NVIDIA Corporation\NVIDIA App\osc\index.html
```

and resolves the `main.<hash>.js` file currently referenced by that page.

Only when this cannot be resolved does it fall back to the newest `main.*.js` file.

This reduces the risk of patching an obsolete JavaScript bundle left behind after an NVIDIA update.

## 2. FileSystemWatcher + debounce

The provider watches:

```text
C:\Program Files\NVIDIA Corporation\NVIDIA App\osc\
```

for changes to the active frontend, especially:

```text
index.html
main.*.js
```

When a change is detected, v3 waits about **30 seconds** before attempting repair. This gives NVIDIA's installer time to finish replacing its files.

A periodic **5-minute fallback check** is also present in case a filesystem notification is missed.

## 3. Strict compatibility anchors

v3 uses a compatibility profile containing multiple independent code anchors.

For the current profile, every required anchor must occur **exactly once** before a patch is allowed.

The anchors cover the relevant areas for:

- reusing the CPU-clock metric as Battery
- injecting Battery/GPU-temperature values into PerfMon
- starting the local telemetry polling bridge
- selecting the custom metric set
- forcing top-center placement
- stabilizing the metric category order

If an anchor is missing or ambiguous:

```text
PATCH ABORTED
```

The new NVIDIA bundle remains untouched.

A new SHA-256 alone is therefore not automatically considered incompatible. Minor NVIDIA updates can still be accepted when the relevant structure is unchanged and all anchors remain unique.

## 4. SHA-256 versioned clean backups

Before patching, the clean NVIDIA JavaScript is stored under:

```text
C:\ProgramData\NVOverlayBatteryPatch\backups\<SHA256>\
```

Example:

```text
backups\
└── 60D68F20...CAFED5\
    ├── main.deaee2ff72bfcecf.js
    └── meta.json
```

Backups are keyed by the hash of the clean NVIDIA source.

This prevents v3 from intentionally restoring an old NVIDIA JavaScript bundle over a newer NVIDIA build.

## 5. Atomic replacement

v3 first generates the patched bundle as a temporary file.

Before the live NVIDIA file is touched, the patcher checks that:

- the v3 patch marker exists
- every expected replacement exists
- the output-size change is within a sanity limit
- the temporary file can be read back correctly

Only then is the live file replaced using a same-volume atomic replacement operation.

This avoids gradually rewriting a multi-megabyte JavaScript file while NVIDIA CEF is trying to read it.

## 6. Runtime smoke test and automatic rollback

If NVIDIA Overlay was running before patching, v3 temporarily stops it, performs the atomic replacement and starts the overlay again.

The patcher then checks whether an NVIDIA Overlay process stays alive.

If the patched overlay fails that smoke test:

```text
patched file
    ↓
automatic rollback
    ↓
matching clean SHA-256 backup
    ↓
NVIDIA Overlay restart
```

The goal is to prefer a working unmodified NVIDIA overlay over a broken patched one.

## 7. Repair cooldown

If NVIDIA releases a completely incompatible frontend, v3 does not repeatedly trigger an elevated repair attempt every few seconds.

The same unchanged unsupported file signature is retried only after a cooldown.

---

## Update flow

Compatible NVIDIA update:

```text
NVIDIA App update
      ↓
index.html / main.*.js changes
      ↓
FileSystemWatcher
      ↓
30 s debounce
      ↓
active main bundle resolved
      ↓
v3 marker missing
      ↓
elevated repair task
      ↓
clean source SHA-256 calculated
      ↓
all structural anchors checked
      ↓
versioned clean backup
      ↓
atomic patch
      ↓
NVIDIA Overlay restart
      ↓
runtime smoke test
      ↓
done
```

Unknown/incompatible update:

```text
NVIDIA App update
      ↓
new bundle detected
      ↓
anchor validation fails
      ↓
NO PATCH
      ↓
NVIDIA file remains untouched
      ↓
reason written to state.json + patch.log
```

---

## Files installed

v3 installs its runtime files to:

```text
C:\ProgramData\NVOverlayBatteryPatch\
```

Typical structure:

```text
NVOverlayBatteryPatch\
├── NvBatteryProvider.exe
├── NvBatteryProvider.cs
├── Patch-NvidiaOverlay.ps1
├── README.md
├── patch.log
├── state.json
└── backups\
    └── <SHA256>\
        ├── main.<hash>.js
        └── meta.json
```

The C# provider is compiled locally during installation.

The installer does not download a precompiled third-party telemetry executable.

---

## Logs and state

Log file:

```text
C:\ProgramData\NVOverlayBatteryPatch\patch.log
```

Machine-readable state:

```text
C:\ProgramData\NVOverlayBatteryPatch\state.json
```

Typical states include:

```text
patched
unsupported
rolled-back
```

For unsupported NVIDIA updates, the state can contain information such as:

- NVIDIA version
- source SHA-256
- target bundle
- patch profile
- failing anchor information / reason

This makes it easier to add a compatibility profile for a future NVIDIA build without blindly patching it.

---

## Manual repair

If automatic repair did not run, execute:

```text
Repair.cmd
```

from the extracted release folder.

The script requests administrator rights and runs the installed v3 patcher.

---

## Uninstallation

Run:

```text
Uninstall.cmd
```

v3 will attempt to:

- stop `NvBatteryProvider.exe`
- remove provider autostart
- remove the scheduled repair task
- restore the matching clean NVIDIA backup **only when the active file still contains the v3 patch marker**
- leave an already-newer clean NVIDIA bundle untouched
- restart NVIDIA Overlay when a restore was required
- remove `C:\ProgramData\NVOverlayBatteryPatch`

This is intentional. If NVIDIA has already replaced the patched frontend with a newer clean build, the uninstaller should not copy an old backup over it.

---

# Troubleshooting

## NVIDIA shows `GPU 0°C`

This was one of the original reasons for the project on the Surface Laptop Studio 2.

Check the local provider:

```text
http://127.0.0.1:37921/status
```

When the dedicated NVIDIA GPU is awake, you should ideally see something like:

```json
"gpuTempC": 47.0,
"gpuState": "ACTIVE"
```

If the GPU is currently power-gated or the driver exposes no temperature:

```json
"gpuState": "OFF"
```

In that situation the overlay should prefer:

```text
GPU 0% OFF
```

over an invalid `0°C` temperature.

Start a program/game that actually uses the NVIDIA GPU and check again after several seconds.

## BAT shows `N/A`

Open:

```text
http://127.0.0.1:37921/status
```

If the page cannot be reached, check whether this process is running:

```text
C:\ProgramData\NVOverlayBatteryPatch\NvBatteryProvider.exe
```

You can also sign out/in or start the executable manually for testing.

## Battery wattage changes slowly

This is intentional. The provider averages recent charge/discharge-rate samples so that the HUD does not constantly jump between short transient values.

Because the sample interval is about 2 seconds and the history keeps up to 10 values, the displayed wattage can represent roughly the recent ~20 seconds once the history is full.

The history is cleared immediately when the charge/discharge direction changes.

## Battery temperature is missing

The laptop firmware/Windows battery driver may not expose a usable battery-temperature class.

The project does not fabricate a value. Battery percentage, power and time estimation can continue to work without battery temperature.

## NVIDIA updated and the battery field disappeared

Check:

```text
C:\ProgramData\NVOverlayBatteryPatch\state.json
C:\ProgramData\NVOverlayBatteryPatch\patch.log
```

If the state is:

```text
unsupported
```

then NVIDIA changed the frontend enough that the current compatibility profile could not be applied safely.

A new profile should be created for that build instead of weakening the anchor checks.

## `Install.cmd` reports an unsupported NVIDIA version

This is a safety feature, not necessarily an installer crash.

The patcher found that the active NVIDIA JavaScript no longer matches every required structural anchor uniquely.

Do not turn the patch into a fuzzy blind search/replace. Inspect the new clean `osc\main.<hash>.js`, map the equivalent code paths and create a new compatibility profile.

---

# Security model

The project deliberately avoids NVIDIA DLL patching and does not inject its own code into games.

It modifies the local NVIDIA **CEF/OSC frontend JavaScript** and runs a small local telemetry provider.

The provider:

- listens only on `127.0.0.1`
- serves read-only battery/GPU telemetry
- does not need Internet access
- does not download code
- does not attempt to bypass anti-cheat, DRM or game security controls

The NVIDIA App continues to provide the actual overlay/game rendering path.

Administrator rights are required because the NVIDIA frontend lives under `Program Files` and must be modified.

---

# Limitations

This project relies on NVIDIA implementation details that are not a public extension API.

Therefore:

- a major NVIDIA App frontend redesign can require a new compatibility profile
- NVIDIA updates can overwrite the patch before v3 reapplies it
- v3 can automatically repair only structurally compatible updates
- CPU/GPU/battery sensor availability depends on the laptop, firmware, Windows and NVIDIA driver
- battery temperature is not available on many laptops
- when the dedicated GPU is fully power-gated, no real temperature may exist to display and `OFF` is expected
- with multiple NVIDIA GPUs, the current fallback uses the highest valid temperature found
- game-specific or anti-cheat-specific NVIDIA overlay restrictions still apply
- the time-to-empty/full value is an estimate based on current reported battery rate and can change quickly with workload

The goal is not:

> patch every future NVIDIA release at any cost

The goal is:

> **keep a useful laptop HUD working across compatible updates, and fail safely when NVIDIA changes too much.**

---

# Development notes

Project structure:

```text
NVOverlayBatteryPatch_v3/
├── Install.cmd
├── Install.ps1
├── Repair.cmd
├── Repair.ps1
├── Uninstall.cmd
├── Uninstall.ps1
├── Patch-NvidiaOverlay.ps1
├── NvBatteryProvider.cs
└── README.md
```

When adding support for a new NVIDIA build:

1. Obtain the clean active `osc\main.<hash>.js`.
2. Record its SHA-256.
3. Compare the relevant metric/overlay code with the current profile.
4. Identify the equivalent anchors for Battery, GPU temperature, polling, metric selection and position.
5. Add/adjust a profile only when every required anchor can be identified uniquely.
6. Generate the patch in a temporary file and validate it before touching NVIDIA's live file.
7. Test NVIDIA Overlay startup after the patch.
8. Preserve the rule: **unknown build = no modification**.

A false positive inside a multi-megabyte minified JavaScript bundle is more dangerous than requiring a manual compatibility update.

---

# Deutsch

## Was macht das Projekt?

`NVIDIA Overlay Battery Patch` erweitert das vorhandene NVIDIA-Performance-Overlay speziell für **Notebooks/Laptops**.

Statt hauptsächlich Desktop-/Benchmark-Werte wie CPU-Takt anzuzeigen, konzentriert sich das Overlay auf Werte, die unterwegs und beim Spielen auf Akku wichtig sind:

```text
CPU 16% 54°C | BAT 78% ↓14.6W 4:12 | GPU 8% 47°C
```

Dabei bleiben NVIDIAs eigenes Overlay, die Vollbilddarstellung und der Hotkey:

```text
Alt + R
```

erhalten.

Das Projekt zeigt – soweit das jeweilige Notebook die Sensoren bereitstellt – Akkustand, Lade-/Entladeleistung, geschätzte Restzeit, optionale Akkutemperatur sowie CPU-/GPU-Auslastung und Temperaturen.

## Warum ist das besonders für Laptops sinnvoll?

Auf einem Laptop sagt die reine CPU- oder GPU-Leistung nicht, wie lange das Gerät unter der aktuellen Last noch durchhält. Gerade beim Spielen, Kompilieren, Rendern oder bei hoher Hintergrundlast ist interessant, ob das Notebook beispielsweise nur 8 W oder 50 W aus dem Akku zieht.

Mit dem Patch kann man direkt im gleichen HUD sehen, ob eine Anwendung den Verbrauch stark erhöht und wie sich das ungefähr auf die Restlaufzeit auswirkt.

## Surface Laptop Studio 2 Temperatur-Fix

Beim Surface Laptop Studio 2 trat das Problem auf, dass NVIDIAs eigener GPU-Temperaturwert im Overlay teilweise:

```text
0°C
```

anzeigte.

v3 verlässt sich deshalb nicht ausschließlich auf diesen Wert. Der lokale Provider versucht die Temperatur direkt über **NVML** aus dem NVIDIA-Treiber zu lesen. Falls das nicht klappt, wird `nvidia-smi` als Fallback verwendet.

Wenn eine echte Temperatur verfügbar ist, wird sie in NVIDIAs `gpuTemp`-Anzeige eingesetzt. Wenn die dedizierte GPU durch Optimus/Hybrid-Grafik tatsächlich abgeschaltet bzw. power-gated ist und keine Temperatur geliefert wird, zeigt der Patch lieber:

```text
OFF
```

statt eines irreführenden `0°C`.

Sobald ein Spiel oder eine andere Anwendung die NVIDIA-GPU aufweckt und der Treiber wieder eine Temperatur liefert, erscheint automatisch wieder der echte Temperaturwert.

## Installation kurz

1. Release-ZIP vollständig entpacken.
2. `Install.cmd` starten.
3. UAC bestätigen.
4. Auf `INSTALLATION FERTIG` warten.
5. Falls das Overlay nicht sichtbar ist: `Alt + R`.
6. Optional den Provider prüfen unter:

```text
http://127.0.0.1:37921/status
```

## Update-Sicherheit

v3 überwacht den NVIDIA-OSC-Ordner. Nach einem NVIDIA-App-Update wird die neue aktive `main.<hash>.js` erkannt. Der Patcher wartet kurz, prüft mehrere eindeutige Code-Anker, legt ein SHA-256-versioniertes Original-Backup an und patcht nur dann, wenn die Struktur sicher kompatibel ist.

Wenn NVIDIA den Aufbau stark geändert hat, wird **nicht** blind gepatcht. Die Datei bleibt unverändert und der Grund steht in:

```text
C:\ProgramData\NVOverlayBatteryPatch\state.json
C:\ProgramData\NVOverlayBatteryPatch\patch.log
```

Damit ist v3 nicht "magisch für jede zukünftige NVIDIA-Version kompatibel", aber deutlich update-resistenter und vor allem so gebaut, dass unbekannte Updates möglichst nicht durch einen falschen Patch beschädigt werden.

---

## Disclaimer

Use at your own risk. NVIDIA App updates can change internal implementation details at any time.

This project is intended for local customization of a user's own Windows installation. It does not bypass licensing, DRM, anti-cheat or other security controls.
