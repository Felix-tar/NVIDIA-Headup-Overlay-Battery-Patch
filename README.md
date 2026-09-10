# NVOverlay Battery Patch v3

A small Windows patch that extends the NVIDIA App performance overlay with battery information while keeping the native NVIDIA overlay, hotkey, fullscreen behavior, CPU/GPU telemetry, and top-center placement.

The project is intentionally designed to **fail safely after NVIDIA App updates**. It only patches a build when all expected code anchors are found exactly once. Unknown layouts are left untouched.

> **Important:** This is an unofficial community project. It is not affiliated with or endorsed by NVIDIA.

---

## What it shows

The target layout is intentionally compact:

```text
CPU 16% 54°C | BAT 78% ↓14.6W 4:12 | GPU 8% 47°C
```

While charging:

```text
CPU 11% 52°C | BAT 63% ↑36.8W 0:51 | GPU 2% 46°C
```

Depending on which sensors Windows and the device firmware expose, the BAT field can contain:

- battery percentage
- battery temperature
- charge/discharge power in watts
- estimated time until empty/full

GPU temperature uses NVIDIA's normal overlay metric first. If that reports no useful temperature, the patch can use the local provider's NVML / `nvidia-smi` fallback.

The NVIDIA hotkey remains:

```text
Alt + R
```

---

# Deutsch

## Installation

1. Download the release ZIP and extract it completely.
2. Double-click **`Install.cmd`**.
3. Confirm the Windows UAC prompt.
4. Wait until **`INSTALLATION FERTIG`** is displayed.
5. If the NVIDIA statistics overlay is hidden, press **`Alt + R`** once.

An existing v1/v2 installation does **not** need to be removed first. v3 detects an older patch and rebuilds the new patch from the clean `.nvbo-original` backup.

### Local status page

After installation, open:

```text
http://127.0.0.1:37921/status
```

Example response:

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

The service binds to **127.0.0.1 only**. It is not exposed to the LAN.

---

## Was v3 update-resistenter macht

v3 does not try to make NVIDIA updates impossible. Instead, it detects them and reapplies the patch only when the new build is structurally compatible.

### 1. Active bundle detection

The patcher first reads NVIDIA's `osc\index.html` and resolves the currently referenced:

```text
main.<hash>.js
```

Only if this fails does it fall back to the newest `main.*.js`.

This prevents accidentally patching an obsolete bundle left behind after an NVIDIA update.

### 2. FileSystemWatcher + debounce

The provider watches:

```text
C:\Program Files\NVIDIA Corporation\NVIDIA App\osc\
```

for changes to:

```text
index.html
main.*.js
```

When NVIDIA changes these files, v3 waits **30 seconds** before checking the installation. This avoids modifying files while the NVIDIA installer is still writing them.

A **5-minute fallback check** remains active in case Windows misses a filesystem event.

### 3. Safe compatibility profiles

v3 contains patch profiles made from multiple independent code anchors.

Every required anchor must occur **exactly once**.

If one anchor is missing or ambiguous:

```text
PATCH ABORTED
```

The new NVIDIA file is left unchanged.

The current profile was explicitly tested against:

```text
main.deaee2ff72bfcecf.js
SHA-256:
60D68F2040C2B92CF97A13D83F81ACCDF4ABE7D681842D9D51ADEB99C9CAFED5
```

A different SHA-256 can still be accepted if **all structural anchors remain uniquely compatible**.

### 4. SHA-256 versioned backups

Clean NVIDIA originals are stored under:

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

v3 therefore never intentionally restores an old NVIDIA JavaScript bundle over a newer NVIDIA version.

### 5. Atomic replacement

The patched JavaScript is first generated as a temporary file.

v3 verifies the temporary output before touching the live NVIDIA bundle and then uses a same-volume `File.Replace` operation.

The live bundle is therefore not gradually rewritten while CEF is reading it.

### 6. Runtime smoke test and rollback

If the NVIDIA overlay was already running before patching, v3 restarts it and checks that an NVIDIA Overlay process remains alive.

If the patched overlay fails this smoke test:

```text
patched file
    ↓
automatic rollback
    ↓
clean SHA-256 backup
    ↓
NVIDIA Overlay restart
```

### 7. Repair cooldown

If a completely new NVIDIA version is incompatible, the provider does not continuously hammer the elevated repair task.

The same unchanged file signature is retried only after a cooldown.

---

## Files installed

v3 installs its files to:

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

No precompiled third-party executable is downloaded by the installer.

---

## Update flow

Normal compatible NVIDIA update:

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
SHA-256 clean backup
      ↓
all patch anchors checked
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

## Logs and state

Log:

```text
C:\ProgramData\NVOverlayBatteryPatch\patch.log
```

Machine-readable state:

```text
C:\ProgramData\NVOverlayBatteryPatch\state.json
```

Typical states:

```text
patched
unsupported
rolled-back
```

If an NVIDIA update changes the internal frontend structure, `state.json` records the NVIDIA version, source SHA-256, profile, target file and failure reason.

This information is useful when adding a new compatibility profile.

---

## Manual repair

If the automatic repair did not run:

```text
Repair.cmd
```

Run it from the extracted release folder.

The script requests administrator rights and executes the installed v3 patcher.

---

## Uninstallation

Run:

```text
Uninstall.cmd
```

v3 will:

- stop `NvBatteryProvider.exe`
- remove provider autostart
- remove the scheduled repair task
- restore the matching clean NVIDIA backup **only if the currently active file still contains the v3 patch marker**
- leave a newer clean NVIDIA build untouched
- restart NVIDIA Overlay when a restore was necessary
- remove `C:\ProgramData\NVOverlayBatteryPatch`

This behavior is deliberate: if NVIDIA has already replaced the patched bundle with a newer clean version, the uninstaller does not copy an old backup over it.

---

## Troubleshooting

### NVIDIA overlay shows battery data, but GPU temperature is `0°C` or `OFF`

On hybrid/Optimus laptops the dedicated NVIDIA GPU may be completely power-gated while idle.

Start a program that actually uses the NVIDIA GPU and check again after a few seconds.

The provider attempts:

```text
NVML
 ↓
nvidia-smi fallback
 ↓
OFF if the driver exposes no temperature
```

`OFF` is preferred over inventing a temperature.

### BAT shows `N/A`

Open:

```text
http://127.0.0.1:37921/status
```

If the page cannot be reached, restart:

```text
C:\ProgramData\NVOverlayBatteryPatch\NvBatteryProvider.exe
```

or sign out/in.

### Battery temperature is missing

Many laptops do not expose battery temperature through the Windows WMI battery classes.

The patch does not fabricate a value. Other battery fields continue to work.

### NVIDIA updated and the patch disappeared

Check:

```text
C:\ProgramData\NVOverlayBatteryPatch\state.json
C:\ProgramData\NVOverlayBatteryPatch\patch.log
```

If the state is `unsupported`, the NVIDIA frontend changed enough that the current profile cannot be applied safely. A new profile must be created for that NVIDIA build.

### `Install.cmd` reports an unsupported NVIDIA version

This is a safety feature, not an installer crash.

Do not weaken the anchor checks just to make a new version patch.

Instead, inspect the new `osc\main.<hash>.js`, identify the equivalent code paths, and add a new compatibility profile.

---

## Security model

The project deliberately avoids modifying NVIDIA DLLs or injecting code into games.

It changes the local NVIDIA CEF/OSC frontend JavaScript and runs a local telemetry provider.

The provider:

- listens only on `127.0.0.1`
- serves read-only battery/GPU telemetry
- does not require network access
- does not download code
- does not attempt to bypass anti-cheat software

The NVIDIA App itself still provides the actual in-game/fullscreen overlay rendering.

---

## Limitations

NVIDIA does not provide a public supported extension API for this use case.

Therefore:

- a major NVIDIA App frontend redesign can require a new patch profile
- NVIDIA can overwrite the patch during an update
- v3 can automatically repair only updates that remain structurally compatible
- sensor availability depends on the laptop firmware, Windows and NVIDIA driver
- anti-cheat/game-specific NVIDIA overlay restrictions still apply

The goal of v3 is not "patch every future build at any cost". The goal is:

> **Automatically repair compatible updates and safely refuse incompatible ones.**

That is much safer than blindly modifying minified JavaScript after every NVIDIA release.

---

# English quick start

1. Extract the ZIP.
2. Run **`Install.cmd`**.
3. Accept UAC.
4. Wait for `INSTALLATION FERTIG`.
5. Press **`Alt + R`** if the NVIDIA statistics overlay is hidden.
6. Verify the local provider at:

```text
http://127.0.0.1:37921/status
```

v3 automatically watches the NVIDIA OSC frontend for updates. Compatible builds are repatched after a short debounce. Unknown builds are left untouched and reported in `state.json` / `patch.log`.

---

## Project structure

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

---

## Development notes

When adding support for a new NVIDIA build:

1. Obtain the clean active `osc\main.<hash>.js`.
2. Record its SHA-256.
3. Compare the relevant metric and overlay code with the current profile.
4. Add/adjust a profile only when each anchor can be identified uniquely.
5. Test the generated patch before allowing automatic repair.
6. Keep the "unknown build = no modification" behavior.

Do not turn the patcher into a fuzzy search-and-replace tool. A false positive inside a multi-megabyte minified bundle is more dangerous than requiring a manual profile update.

---

## Disclaimer

Use at your own risk. NVIDIA App updates can change internal implementation details without notice.

This project is intended for local customization of a user's own Windows installation. It does not bypass licensing, anti-cheat, DRM, or security controls.
