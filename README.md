# LionCar

A free, open-source iPhone app for your own connected **Peugeot, Citroën, DS, Opel or Vauxhall**. It is an iPhone port of
the Android app [LionFlow](https://github.com/thocubeat/lionflow) and an unofficial alternative to the MyPeugeot,
MyCitroën, MyDS, myOpel and MyVauxhall apps. It signs in with your normal brand account and talks to the same Stellantis
servers, so it shows the same car data and sends the same remote commands.

No ads, no analytics, no LionCar server.

## Status: what has been tried on a real car

LionCar is young. Some parts have run against a real car and the brand's real servers; others are ported from LionFlow
and checked only with automated tests and made-up car data.

| | Tried on a real car | Notes |
|---|---|---|
| Sign-in, staying signed in | ✅ | |
| Car status, map, service | ✅ | on a fuel-powered car |
| Trips | ✅ | on a fuel-powered car |
| Remote control setup (SMS + security code) | ✅ | |
| Stats, fill-ups, fuel cost, tags, CSV, all car data | ⚠️ not confirmed yet | built from the same data as the trips; tested with made-up data |
| Map with chargers / fuel stations | ⚠️ not confirmed yet | the OpenStreetMap search was tested live (Paris) |
| Lock, unlock, lights, horn, **Update now** | ⚠️ not confirmed yet | the commands go out like LionFlow's; first real-car reports pending |
| Notifications | ⚠️ not confirmed yet | timing depends on iOS |
| **Everything for electric and plug-in hybrid cars** (incl. scheduled start) | ❌ **not tested** | no such car was available — see below |

Reports of what works (or doesn't) on your car are very welcome — please open an issue.

> LionCar is independent and is not made, endorsed or supported by Stellantis, Peugeot, Citroën, DS Automobiles, Opel or
> Vauxhall. Brand and app names are trademarks of their owners and only say which cars the app works with. Remote
> commands act on a real car: make sure it is safe to lock, unlock or sound the horn.

## Features

### Stays signed in
The brand's server hands out a **new refresh token every time** the sign-in is renewed, and the old one stops working. An
app that loses the new token is signed out — a common complaint about the official apps. LionCar saves every new token in
the iPhone's **Keychain** before it does anything else, and never runs two renewals at once.

### Car tab
- Fuel or battery level with range; for plug-in hybrids both
- Electric and plug-in hybrid cars also get a **Charging** and a **Pre-heating** card (⚠️ untested, see below)
- **Locked / unlocked**, which doors, boot or windows are open, alarm on or off
- When the car last reported, with **Update now**: wakes the car so it sends a fresh report (the server otherwise only has
  the last report, which can be hours old when the car is parked)
- A note when the car itself **hasn't sent new data for hours**, with what usually helps (a short drive, or locking and
  unlocking with the key) — so it doesn't look like the app is stuck
- Where the car is parked, which way it faces, and walking directions in Apple Maps
- Odometer, outside temperature, next service (km and days), engine warm or cold, drive mode and gearbox
- **Average consumption since new**, from the car's own fuel counter
- Banners when the car is being driven, when privacy mode is on (it blocks remote commands), and when fog lights are left on
- Warnings the car reports
- **All car data**: every value the car sends in plain words, plus the raw data
- **Customizable**: reorder or hide the cards

### Remote control
- **Lock, unlock, flash the lights, sound the horn** — over the same MQTT channel and one-time codes as the brand apps
- Shows each step while a command is on its way ("Waking the car…", "Car received it") and the car's own reason when it
  refuses (door open, key inside, privacy mode…)
- **Face ID** before unlocking or sounding the horn
- One-time setup with an SMS code and your brand app's 4-digit security code
- A command log for troubleshooting

### Trips
- **7 days, 30 days, 3 months or 1 year**
- Distance, duration, average and top speed, fuel or energy used, consumption, **tank level and range at start and end**,
  map of start and end
- **Fuel cost** per trip, per period and per tag (set your price per litre)
- **Tags** (Home, Work…): automatic for trips that start or end at a tag's place, or chosen by hand; totals per tag; filter
- **CSV export** through the share sheet

### Stats
- Monthly chart and totals: distance, fuel, cost, trips, time at the wheel, consumption
- **Fill-ups**, found from the fuel gauge, with estimated litres and cost (the tank size is worked out from the gauge, or
  set it yourself)
- Records: longest trip, longest time at the wheel, most in one day, most economical and thirstiest trip
- Since new: odometer, average consumption, fuel used and its cost

### Map
- **Chargers** for electric and plug-in hybrid cars, **fuel stations** for petrol, diesel and mild-hybrid cars — from
  OpenStreetMap, free and without an account or key
- You and your car on Apple Maps, 2D or 3D; "All" or "Fast 50 kW+" chargers; **Search this area** after moving the map
- Tap a place for its power, number of points, plug types (CCS, Type 2, CHAdeMO…), operator, address, opening hours, the
  distance from you and from the car, and driving directions
- The search asks the free public Overpass servers, which are often busy: LionCar checks them first and takes the first
  good answer (and still tries servers whose status page doesn't answer). Results are kept for 6 hours, and older saved
  ones are shown while it searches. OpenStreetMap is made by volunteers, so power, plugs and prices can be missing

### Electric and plug-in hybrid cars — ⚠️ untested on a real car
> **⚠️ None of this has been tried on a real electric or plug-in hybrid car yet.** It is ported from LionFlow, where it
> works, and the logic is covered by automated tests with made-up car reports — but no such car was available for
> testing. The app shows a warning under each of these screens. Try it in **demo mode** first, and if you own such a car,
> please report what works and what doesn't. Commands like "Charge now" act on your real car.

- **Charging card:** charging state, **real charging power in kW** (worked out from the energy going into the battery;
  estimated until two reports are in), time left and the time it reaches your limit or 100 %
- **Start / stop charging**, and the car's own limit: **daily limit or full charge for a trip**
- The car's **scheduled start** time, with **Turn off**: "Stop charging" works by setting a scheduled start, which used
  to stay on, so the car then waited for it the next time it was plugged in
- **"Charged to X %" notification** at the time the car should reach your target — iOS delivers it on time even when
  LionCar isn't running, so it is the dependable way on iPhone to stop at a %
- **LionCar's own charge limit** and **charging times** ("only charge between 22:00 and 06:00"). Off by default. ⚠️ They
  only act while LionCar runs (open, or a background check iOS allowed — often only every hour or two), so the car can
  charge past the limit or outside the times. The car's own daily limit is more reliable
- **Pre-heating** now or stop, and the car's **4 weekly schedules** ("ready at 07:15, Monday to Friday"); plug-in hybrids
  are only asked when the battery has at least 50 % or the car is plugged in, like the official app
- **Charging log:** every session LionCar sees, with time, % from–to, kWh, duration, average and peak kW, AC or DC,
  where (home, up to 5 known chargers, or the street address), estimated cost; totals for the last 30 days, home vs.
  away; a **battery-health estimate** from the sessions. ⚠️ A charge that starts and ends while LionCar isn't running is
  missed (LionFlow on Android checks every ~10 minutes; iOS doesn't allow that)
- **Range estimate** when the server reports 0 km, and LionFlow's fix for cars that suddenly report a lower level with
  the same energy in the battery

### Demo mode
**Settings › Try with a sample car** (or on the sign-in screen, without an account) shows a made-up car: choose an
**electric car**, a **plug-in hybrid** or a **petrol / diesel car**, of any brand. The electric car shows charging,
pre-heating and a charging log; the hybrid and petrol / diesel cars come with four months of trips, so fuel cost,
fill-ups and records have something to show. Nothing is sent to any car, and your real account and remote-control
setup are left alone. Leave it with **Exit**.

### Notifications
Car left unlocked, low fuel or battery (you choose the %), service due soon, fog lights left on — and for electric cars
"Charged to X %" (⚠️ untested). iOS decides how often the app may check in the background — often every hour or two — so
a warning can come late.

### Every Stellantis powertrain
- **Petrol and diesel:** tank, range, consumption
- **48 V mild hybrids** (the "Hybrid" versions of recent Peugeot, Citroën, DS, Opel and Vauxhall models): shown as fuel cars, plus the small 48 V battery's charge
  and health. Fuel figures are **calibrated per car**: the car's fuel unit is undocumented and differs between models
  (on some mild hybrids the usual guess reads about 2.5× too high)
- **Plug-in hybrids and electric cars:** battery, range, charging state, time left, battery health and capacity, and
  the charging and pre-heating features above (untested on a real car)

### Design
- On iOS 26 and later, Apple's **Liquid Glass**: glass buttons (Lock / Unlock, Charge now…), glass controls floating over
  the map, a toast on glass, a tab bar that shrinks while you scroll, and rounder cards. Content stays solid, as Apple
  recommends; older iOS versions keep the previous look

### Languages
English, Greek and Dutch (follows the iPhone, or choose under iPhone Settings › LionCar › Language). Much of the Dutch
comes from LionFlow's own translation.

## LionCar compared with LionFlow (Android)

| | LionFlow (Android) | LionCar (iPhone) |
|---|---|---|
| Brands, countries, sign-in on the brand's own page | ✅ | ✅ |
| Stays signed in (rotating refresh tokens) | ✅ | ✅ |
| Status: fuel/battery, range, doors, odometer, position, service | ✅ | ✅ |
| Every value the car reports, raw data | — | ✅ |
| Customizable home screen | — | ✅ (reorder / hide cards) |
| Several cars on one account | ✅ | ✅ |
| Several accounts at once | ✅ | — |
| Lock, unlock, lights, horn | ✅ | ✅ |
| Wake the car for fresh data | ✅ automatically when the app opens | ✅ "Update now" button |
| Pre-heating now and weekly schedules | ✅ | ✅ ⚠️ untested on a real car |
| Start/stop charging, car's charge limit (daily / full) | ✅ | ✅ ⚠️ untested on a real car |
| Charging power in kW, time to limit | ✅ | ✅ ⚠️ untested on a real car |
| "Charged to X %" reminder | phone alarm | ✅ notification ⚠️ untested on a real car |
| App's own charge limit and charging window | ✅ checks every ~10 min | ✅ ⚠️ untested; only acts while the app runs |
| Charge past the car's limit, smart (weather) schedule | ✅ | — (needs checks every few minutes) |
| Charging log with real kW, home/away, costs, battery health | ✅ | ✅ ⚠️ untested; misses charges while the app isn't running |
| Range estimate when the server reports 0 km | ✅ | ✅ ⚠️ untested on a real car |
| Turn off the car's scheduled start | ✅ | ✅ ⚠️ untested on a real car |
| Demo mode: electric, plug-in hybrid or petrol / diesel, any brand | ✅ | ✅ (also while signed in) |
| Note when the car hasn't sent data for hours | ✅ | ✅ |
| Wake-ups back off when the car doesn't answer | ✅ (for its automatic wake-ups) | — not needed: LionCar only wakes the car when you tap "Update now" |
| 48 V mild hybrid support | ✅ | ✅ plus 48 V battery and per-car fuel calibration |
| Trips | ✅ | ✅ 7 days to 1 year |
| Trip tags | ✅ | ✅ |
| CSV export / import | ✅ / ✅ | ✅ / — |
| Fuel cost per trip and month | — | ✅ |
| Monthly stats, fill-ups, records, average since new | — | ✅ |
| Own service history | ✅ | not yet |
| Route recording via the car's Bluetooth | ✅ | — (iOS can't reliably detect it in the background) |
| Map with chargers | ✅ 2D/3D, OpenStreetMap or NOBIL (with a key) | ✅ 2D/3D on Apple Maps, OpenStreetMap; plug types and opening hours; fuel stations for fuel cars |
| NOBIL charger data (Nordic countries, needs a key) | ✅ | — not ported (needs a NOBIL API key in the build) |
| EV trip planner with charging stops | ✅ | not yet |
| Weather and forecast | ✅ | not yet |
| Notifications | ✅ | ✅ (timing decided by iOS) |
| Home-screen widget | ✅ | not yet |
| Watch app | ✅ Wear OS, you choose what it shows | not yet (Apple Watch) |
| In-car app | ✅ Android Auto, with the car's speed and your choice of what it shows | — (CarPlay needs an Apple entitlement this project can't get) |
| App lock with fingerprint/code | ✅ | Face ID before unlock and horn |
| Languages | English, French, German, Spanish, Norwegian, Dutch | English, Greek, Dutch |
| Updates | updates itself | reinstall from source (see below) |

## Install

LionCar is not on the App Store. You build it from this repository and install it on your iPhone with a **free Apple
ID**, using [xtool](https://xtool.sh) — it builds, signs and installs iPhone apps on **Linux, macOS or Windows (WSL)**,
without the Xcode IDE.

**You need:** a computer, a USB cable for the iPhone, an Apple ID (a free one is enough), about 15 GB of free disk space
for the iOS SDK, and your car added in the brand's own app.

### 1. Set up the tools (once)

On Linux (Ubuntu/Debian shown; see [xtool's guide](https://xtool.sh/documentation/xtool/installation-linux) for others,
and [the macOS guide](https://xtool.sh/documentation/xtool/installation-macos) for a Mac):

```bash
# Swift 6.4, with swiftly
curl -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
tar zxf "swiftly-$(uname -m).tar.gz" && ./swiftly init      # then open a new terminal
swiftly install 6.4

# what Swift and the iPhone connection need
sudo apt-get install -y usbmuxd libimobiledevice-utils binutils libcurl4-openssl-dev libxml2-dev zlib1g-dev

# xtool 1.24
curl -fL "https://github.com/xtool-org/xtool/releases/download/1.24.0/xtool-$(uname -m).AppImage" -o xtool
chmod +x xtool && mv xtool ~/.local/bin/
```

Download **Xcode** as a `.xip` file from [developer.apple.com/download/all](https://developer.apple.com/download/all/?q=Xcode)
(sign in with your Apple ID; the note that it needs a Mac doesn't matter — xtool only takes the iOS SDK out of it).
Then run, in a normal terminal:

```bash
xtool setup
```

Choose **Password** (works with free Apple IDs), enter your Apple ID, password and the two-factor code, and give the path
to the Xcode `.xip`.

### 2. Install LionCar

```bash
git clone https://github.com/t-shock/lionCar-iOS.git
cd lionCar-iOS
xtool dev
```

Connect the iPhone by USB, unlock it, and tap **Trust** when it asks. The first time, iOS asks you to turn on
**Developer Mode** (Settings › Privacy & Security › Developer Mode; the iPhone restarts), then run `xtool dev` again. If
iOS says the developer isn't trusted, open Settings › General › VPN & Device Management, tap your Apple ID and **Trust**.

### 3. First start

1. Pick your car's **brand and country** and tap **Sign in** — you log in on the brand's own page.
2. Optional, for lock/unlock: **Set up remote control** → Send SMS code → enter the SMS code and your brand app's 4-digit
   security code → Activate. Do this only once: after about 20 SMS activations Stellantis locks remote setup for the
   account (error `NOK:MAXNBTOOLS`), and unlocking it means reinstalling the brand app.
3. Allow notifications, and keep **Background App Refresh** on for LionCar (iPhone Settings › LionCar).

No car, or want to look around first? **Try with a sample car** on the sign-in screen opens demo mode.

## Every 7 days

Apps installed with a **free** Apple ID stop opening after **7 days**. Re-installing renews them, and **nothing is lost**:
your sign-in, remote control, tags and settings stay on the iPhone.

1. Connect the iPhone by USB and unlock it.
2. In the `lionCar-iOS` folder run:
   ```bash
   git pull     # optional: also gets the latest version
   xtool dev
   ```

That's all. A calendar reminder every 6 days helps.

- **Missed it?** LionCar just won't open until you re-install it the same way. Your data is still there.
- **Don't delete the app** to fix it: deleting it removes its data (you would have to sign in and set up remote control
  again, which uses up an SMS activation).
- A free Apple ID can have only 3 such apps installed at once.
- With a paid Apple Developer account ($99/year) an install lasts a year.
- Want it to renew on the phone by itself? Build an `.ipa` with `xtool dev build --ipa` and install it with
  [SideStore](https://sidestore.io), which refreshes apps over Wi-Fi in the background.

## Privacy and security

- LionCar talks only to the brand's servers (sign-in, car data, remote commands), to Apple's map services (the maps,
  and street names for the charging log), and — when you open the Map tab — to the public OpenStreetMap Overpass
  servers. There is no LionCar server and nothing is collected.
- The Map tab asks for your location, to show where you are. To find chargers or fuel stations, only the map area's
  coordinates are sent to the Overpass servers (which can be your own area); nothing about you, your account or your car.
- Sign-in tokens, the remote-control state and your security code are kept in the iPhone's **Keychain**, only on this
  device (not synced to iCloud). Car data, trips and settings stay in the app.
- Your password is only ever typed on the brand's own sign-in page; LionCar never sees it.
- The client IDs in `Core/Sources/LionCore/StellantisConfigsData.swift` are the brand apps' public ones, the same as in
  LionFlow and the Home Assistant integration — not anyone's personal keys.
- The test data in `Core/Tests/LionCoreTests/Fixtures` is made up (`scripts/make_fixtures.py`); no real car's data is
  in this repository.

## For developers

- `Core/` — the car logic (sign-in, API, status and trip parsing, one-time codes, MQTT remote control, stats, tags,
  warnings, charging power and log, charge limit and window, demo car) as a plain Swift package. It builds and is tested
  on Linux: `cd Core && swift test`. All test data is made up (`scripts/make_fixtures.py`, `EVTests.swift`).
- `Sources/LionCar/` — the SwiftUI app.
- `translations/<language>.json` — translations. `scripts/extract_strings.py Sources/LionCar` lists the app's texts;
  `scripts/make_strings.py` builds the iOS files from the JSON.
- `design/make_icon.py` — draws the app icon.

## Licence

GPL-3.0 — see `LICENSE`. LionCar is based on LionFlow by thocubeat (GPL-3.0); credits and third-party licences are in
`NOTICE.md`.
