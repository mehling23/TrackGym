# TrackGym

Plan your strength training on the iPhone, log every set from the Apple Watch, and let the workout count in Apple Health — a native iOS + watchOS app built with SwiftUI, SwiftData, WatchConnectivity and HealthKit.

[![Build and Test](https://github.com/mehling23/TrackGym/actions/workflows/build.yml/badge.svg)](https://github.com/mehling23/TrackGym/actions/workflows/build.yml)
![Platforms](https://img.shields.io/badge/platforms-iOS%2018%20%7C%20watchOS%2010-blue)
![Swift](https://img.shields.io/badge/Swift%206-strict%20concurrency-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<p align="center">
  <img src="docs/screenshots/01-plans.png" width="180" alt="Training plans on the iPhone">
  <img src="docs/screenshots/02-active-workout.png" width="180" alt="Live workout with rest timer, notes and last session's numbers">
  <img src="docs/screenshots/04-progress.png" width="180" alt="Progress charts">
  <img src="docs/screenshots/05-exercises.png" width="180" alt="Exercise catalogue with filters">
</p>
<p align="center">
  <img src="docs/screenshots/03-watch-session.png" width="200" alt="Apple Watch during a set: exercise, heart rate, calories, logged sets and rest timer">
</p>

## What it does

**iPhone — plan, track, review**

- **Training plans** from a catalogue of 77 exercises (German names) grouped by muscle group and equipment, plus your own custom exercises. Drag to set the order the exercises come up in.
- **Live tracking**: start a plan, see last session's sets next to each exercise, pre-filled sets you only adjust, per-exercise notes ("safety pins on 14"), a training clock and a **rest timer** after every logged set.
- **Progress**: weight and volume charts per exercise, personal-record badges, and volume per muscle group for the last week, month or all time. Overall history remains available after an exercise is deleted.
- **Backup**: export and import everything as JSON. Exercises carry stable UUIDs, so a backup restored on a new phone keeps every plan and history link intact.

**Apple Watch — log without touching the phone**

- Shows the current exercise and its sets; log the next set with the Digital Crown. Sets reach the phone instantly, or are queued and delivered later if the phone is out of reach.
- Runs an **HKWorkoutSession** while the workout is active: live heart rate and active calories on the watch face, and the finished strength workout is saved to Apple Health and counts toward the activity rings.
- Rest timer mirrored from the phone with a wrist tap when the pause is over.

The watch is deliberately a logging surface only. Plan setup, history and settings live on the iPhone.

## Architecture

```
TrackGym/                          # iOS app
├── Models/                        # SwiftData @Model types
├── Data/                          # Seeding, JSON backup, WCSession (phone side), statistics
└── Views/                         # SwiftUI screens
TrackGym Watch App Watch App/      # watchOS app — session UI, WCSession (watch side), HealthKit
TrackGymTests/, …AppTests/         # XCTest, in-memory SwiftData
```

- **SwiftUI + SwiftData** on the iPhone. Relationships declare explicit inverses and delete rules; plan exercise order is stored separately because SwiftData to-many relationships are unordered sets.
- **Swift 6 language mode** with main-actor default isolation. Delegate callbacks from WatchConnectivity and HealthKit are `nonisolated` and hop to the main actor with `Sendable` values only — the build is warning-free.
- **WatchConnectivity protocol**: the phone pushes the active exercise via `updateApplicationContext` (survives unreachability, replayed on watch launch) plus a low-latency `sendMessage`. Sets from the watch use an acknowledged `sendMessage` with a `transferUserInfo` fallback; the phone deduplicates by message id with a buffer that survives relaunches, and the watch refuses to replay a context older than four hours.
- **HealthKit on the watch**: `HKWorkoutSession` + `HKLiveWorkoutBuilder`, ended in Apple's documented order, with recovery of a session HealthKit kept alive after a crash. Denied permission degrades gracefully — tracking keeps working, only pulse/calories/rings are missing.
- **Data integrity**: import replaces the store atomically (validated first, rolled back on failure), pre-filled sets the user never touched are discarded rather than written to history, and entries left behind by an interrupted workout are cleaned up at launch.
- **Charts** framework for the progress views.

## Tests & CI

105 unit tests (82 iOS, 23 watchOS) plus 8 UI tests; SwiftData tests use in-memory containers, and UI tests launch with an isolated in-memory store. GitHub Actions builds and tests both platforms on every push. Covered: backup round-trips (ids, order, notes, units, legacy files), import validation and orphan cleanup, duplicate detection, seeding, history lookups, statistics, watch payload parsing and delivery acknowledgements, context ordering, and HealthKit authorization cancellation. UI tests cover plan creation, set validation, partial saves, finishing and cancelling workouts, exercise deletion with preserved history, and filter reset.

```bash
DEST=$(xcrun simctl list devices available \
  | sed -nE 's/.*iPhone.*\(([0-9A-F-]{36})\) \(Shutdown\).*/\1/p' | head -1)

xcodebuild test -project TrackGym.xcodeproj -scheme TrackGym -destination "id=$DEST"

WATCH=$(xcrun simctl list devices available \
  | sed -nE 's/.*Apple Watch.*\(([0-9A-F-]{36})\) \(Shutdown\).*/\1/p' | head -1)

xcodebuild test -project TrackGym.xcodeproj -scheme 'TrackGym Watch App Watch App' -destination "id=$WATCH"
```

## Build

Requires Xcode 26 (Swift 6 toolchain). Deployment targets: iOS 18.0, watchOS 10.0.

```bash
git clone https://github.com/mehling23/TrackGym.git
cd TrackGym
open TrackGym.xcodeproj
```

Run the **TrackGym** scheme on an iPhone (the watch app is embedded and installs on the paired watch) or **TrackGym Watch App Watch App** on a watch directly. A paired iPhone + Apple Watch simulator pair works for the full flow; heart rate on the simulator is synthetic.

To reproduce the screenshots, launch a Debug build with a demo backup:

```bash
xcrun simctl launch <iphone-udid> de.ehling.TrackGym -demoDataPath "$PWD/docs/demo-data.json"
```

## How it was built

Built with an AI-assisted workflow: features start as a short design spec and an implementation plan (see [`docs/superpowers/`](docs/superpowers/)), then get implemented, tested and reviewed with [Claude Code](https://claude.com/claude-code) in the loop — the `Co-Authored-By` trailers in the git history show where. Product decisions, scope and what ships are mine; the test suite and CI are what keep that honest.

## Roadmap

- English localization (UI is German-only today)
- Pause / resume of the HealthKit session
- iCloud sync

## License

[MIT](LICENSE) © 2026 Maximilian Ehling
