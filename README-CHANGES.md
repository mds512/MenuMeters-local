# MenuMeters — private fork

This is [yujitach/MenuMeters](https://github.com/yujitach/MenuMeters) with two
changes:

1. **Everything that phoned home was removed.** No update checks, no system
   profiling, no third-party frameworks.
2. **One outbound path was added, and you own it.** MenuMeters can POST a JSON
   snapshot of its readings to a URL you set, at an interval you set, tagged with
   a device ID you set. It is off until you configure it.

Forked from upstream commit `e91b746`.

---

## 1. What was removed

Upstream's only network activity was the [Sparkle](https://sparkle-project.org)
auto-updater. All of it is gone:

| Removed | Where it was |
| --- | --- |
| `Sparkle.framework` (2.5 MB, vendored) | repository root |
| Update feed `https://member.ipmu.jp/…/MenuMeters-Update.xml` | `MenuMetersApp/AppDelegate.m` |
| `SUSendProfileInfo` — uploaded macOS version, CPU type etc. with every check | `MenuMeters-Info.plist` |
| `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SUPublicDSAKeyFile` | `MenuMeters-Info.plist` |
| "Check for updates…" in the app menu and the Dock menu | `MenuMetersApp/MenuMetersMainMenu.xib` |
| All `#ifdef SPARKLE` code paths | `AppDelegate.m`, `PrefPane/MenuMetersPref.{h,m}` |
| Framework embed + Sparkle codesign build phases | `MenuMeters.xcodeproj` |
| The now-pointless duplicate `MenuMeters No Sparkle` target and scheme | `MenuMeters.xcodeproj` |

Two related cleanups:

- The version comparison used for "kill older instances" used Sparkle's
  comparator; it now uses `NSNumericSearch`, which upstream already used for its
  Sparkle-free build.
- The read-only-volume warning told the user to move the app "so it can
  auto-update". It now explains the real reason (App Translocation breaks
  preference saving).

**Everything else that looks network-shaped is local and was left alone:** the
network meter reads interface counters via `sysctl`, and the PPP reader talks to
a local `AF_LOCAL` socket. Neither sends anything anywhere.

A CI job (`privacy-guard`) fails the build if Sparkle, an analytics SDK, or any
hardcoded `http(s)://` URL in a `.m` file ever reappears.

## 2. What was added

### First run

On first launch a small window asks for a URL, a device ID and an interval, with
a **Not now** button. It appears exactly once either way. Leaving the URL blank
keeps everything on the machine.

### Settings → Reporting

A new tab in the settings window with the same options plus:

- which sections to include (System / CPU / Temperature / Memory / Disk / Network)
- an optional extra request header, e.g. `Authorization: Bearer …`
- **Send test now**, which reports the exact HTTP result
- a live preview of the JSON that will be sent

### The request

`POST` to your URL, `Content-Type: application/json`, 15-second timeout. Failures
are reported in the settings tab and otherwise ignored — there is no retry queue
and nothing is buffered to disk.

The session is `ephemeralSessionConfiguration` with cookies disabled and no URL
cache, so nothing about it persists.

## 3. Payload

Timestamps are ISO 8601 in **IST (`Asia/Kolkata`, +05:30)**. Sections you switch
off are absent rather than empty.

```json
{
  "schema": "menumeters.metrics.v1",
  "device_id": "manny-mbp",
  "host": "mymac.local",
  "timestamp": "2026-08-09T22:41:02+05:30",
  "timestamp_unix": 1786... ,
  "interval_seconds": 60,

  "system": {
    "model": "MacBookPro18,3", "os_version": "14.5",
    "cpu": "Apple M1 Pro", "cpu_speed": "…",
    "cpu_packages": 1, "cpu_cores": 10,
    "architecture": "arm64", "app_version": "2.1.6.1",
    "uptime_seconds": 183422
  },

  "cpu": {
    "user_percent": 12.4, "system_percent": 5.1,
    "total_percent": 17.5, "idle_percent": 82.5,
    "per_core": [ { "core": 0, "user_percent": 9.2,
                    "system_percent": 3.1, "total_percent": 12.3 } ],
    "load_average": { "1m": 1.82, "5m": 1.44, "15m": 1.2 },
    "process_count": 412, "thread_count": 2380,
    "power_limit_status": "…"
  },

  "temperature": {
    "sensor": "TC0P", "sensor_display_name": "TC0P: CPU Proximity",
    "celsius": 45.2, "fahrenheit": 113.36,
    "all_sensors_celsius": { "TC0P": 45.2 }
  },

  "memory": {
    "total_mb": 16384, "used_mb": 9420.5, "free_mb": 6963.5,
    "active_mb": 5120, "inactive_mb": 3200, "wired_mb": 2100,
    "compressed_mb": 1200.5, "used_percent": 57.5,
    "page_ins": 123456, "page_outs": 4321,
    "page_ins_delta": 12, "page_outs_delta": 0,
    "swap": { "file_count": 2, "size_mb": 2048,
              "used_mb": 512, "encrypted": true }
  },

  "disk": {
    "io": { "read_bytes_total": 9876543210, "write_bytes_total": 1234567890,
            "read_bytes_per_sec": 20480.5, "write_bytes_per_sec": 8192 },
    "volumes": [ { "name": "Macintosh HD", "mount_point": "/",
                   "device": "/dev/disk3s1s1", "fs_type": "apfs",
                   "total_bytes": 994662584320, "free_bytes": 402653184000,
                   "used_bytes": 592009400320, "used_percent": 59.52,
                   "read_only": true } ]
  },

  "network": {
    "interfaces": [ { "name": "en0",
                      "bytes_in_total": 9127384, "bytes_out_total": 1827364,
                      "bytes_in_per_sec": 15234.2, "bytes_out_per_sec": 2048.7 } ],
    "totals": { "bytes_in_total": …, "bytes_out_total": …,
                "bytes_in_per_sec": …, "bytes_out_per_sec": … }
  }
}
```

Notes on how to read these:

- **`device_id`** is yours to choose; blank falls back to the hostname, so the
  field is never empty on the receiving end. `host` is always the real hostname.
- **CPU percentages are averaged across cores**, so 100% means every core is
  saturated (unlike `top`, where 100% means one core).
- **`*_per_sec` fields are absent on the very first sample**, because a rate needs
  two samples. Disk rates are also omitted if the counters go backwards, which
  happens when a drive is unmounted.
- **`free_bytes` uses `f_bavail`**, the space actually available to you, which is
  what the Finder shows — not `f_bfree`, which includes reserved blocks.
- **Loopback interfaces are excluded** from the network section.
- **Temperature is absent entirely** if no sensor can be read. Reading *all*
  sensors is off by default: on Intel each read opens and closes the SMC, so
  doing it every interval is not free.

## 4. Files

New:

```
Reporter/MenuMeterReporterSettings.{h,m}              settings, backed by NSUserDefaults
Reporter/MenuMeterReporter.{h,m}                      collection, scheduling, the POST
Reporter/MenuMeterReporterPrefsViewController.{h,m}   the Reporting settings tab
Reporter/MenuMeterReporterSetupWindowController.{h,m} the first-run window
PrefPane/MenuMetersPref+Reporting.{h,m}               appends the tab to the settings window
.github/workflows/build.yml                           CI
```

Two design decisions worth knowing:

- **The reporter samples independently.** It owns its own `MenuMeterCPUStats`,
  `MenuMeterMemStats` and `MenuMeterNetStats`, and reads disk IO and volumes
  directly. So reporting works the same whether or not you have the matching
  menu bar meters switched on.
- **The settings UI is built in code, not in the nib.** `MenuMetersPref.xib` is
  large and translated into a dozen languages; adding a tab in code keeps that
  file untouched. The tab is *appended*, because `openAbout:` selects the About
  tab by hardcoded index.

Sampling and sending happen on one serial background queue, so the menu bar never
stalls waiting on a slow endpoint.

## 5. Building

Push to GitHub and the Actions workflow builds it. Artifacts appear under the
run; tagging `v*` also attaches the zip to a Release.

Locally: `xcodebuild -project MenuMeters.xcodeproj -scheme MenuMeters -configuration Release build`

The build is **universal (Intel + Apple Silicon) and ad-hoc signed**. Ad-hoc is
not a real signature and needs no certificate or Apple account — but it is not
optional either: macOS refuses to run unsigned arm64 binaries at all. The app
still shows as coming from an unidentified developer.

After downloading, macOS quarantines it. Either right-click → **Open**, or:

```sh
xattr -dr com.apple.quarantine /Applications/MenuMeters.app
```

## 6. Privacy

- Reporting is off until you set a URL. With no URL, the app opens no sockets.
- Data goes only to the URL you type. There is no fallback host and no second
  destination.
- Nothing is queued or logged to disk; a failed send is dropped.
- The app is not sandboxed (unchanged from upstream) and needs no extra
  entitlement to make outbound connections.

Two things to be aware of:

- **`NSAllowsArbitraryLoads` is enabled** in `MenuMeters-Info.plist`. Without it,
  App Transport Security blocks plain `http://`, which is what most self-hosted
  endpoints on a LAN actually are. It only relaxes the rules for connections the
  app makes, and the app makes exactly one.
- **The extra header value is stored in `NSUserDefaults`**, i.e. in
  `~/Library/Preferences/com.yujitach.MenuMeters.plist` in plain text. That is
  the same protection your other app preferences get, but if the token is
  sensitive, moving it to the Keychain would be an improvement.

Upstream remains GPL v2; so does this.
