# LionCar

A free, open-source iPhone app for your own connected **Peugeot, Citroën, DS, Opel or Vauxhall**. It is an iPhone port of
the Android app [LionFlow](https://github.com/thocubeat/lionflow) and an unofficial alternative to the MyPeugeot,
MyCitroën, MyDS, myOpel and MyVauxhall apps. It signs in with your normal brand account and talks to the same Stellantis
servers, so it shows the same car data and sends the same remote commands.

No ads, no analytics, no LionCar server.

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
- **Locked / unlocked**, which doors, boot or windows are open, alarm on or off
- When the car last reported, with **Update now**: wakes the car so it sends a fresh report (the server otherwise only has
  the last report, which can be hours old when the car is parked)
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

### Notifications
Car left unlocked, low fuel or battery (you choose the %), service due soon, fog lights left on. iOS decides how often
the app may check in the background — often every hour or two — so a warning can come late.

### Every Stellantis powertrain
- **Petrol and diesel:** tank, range, consumption
- **48 V mild hybrids** (the "Hybrid" versions of recent Peugeot, Citroën, DS, Opel and Vauxhall models): shown as fuel cars, plus the small 48 V battery's charge
  and health. Fuel figures are **calibrated per car**: the car's fuel unit is undocumented and differs between models
  (on some mild hybrids the usual guess reads about 2.5× too high)
- **Plug-in hybrids and electric cars:** battery, range, charging state, time left, battery health and capacity

### Languages
English and Greek (follows the iPhone, or choose under iPhone Settings › LionCar › Language).

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
| Pre-heating now and weekly schedules | ✅ | not yet |
| Start/stop charging, car's charge limit | ✅ | not yet |
| LionFlow's own charge limit, charging window, smart schedule | ✅ | not yet (iOS background limits) |
| Charging log with real kW, home/away, costs | ✅ | not yet |
| Range estimate when the server reports 0 km | ✅ | not yet |
| 48 V mild hybrid support | ✅ | ✅ plus 48 V battery and per-car fuel calibration |
| Trips | ✅ | ✅ 7 days to 1 year |
| Trip tags | ✅ | ✅ |
| CSV export / import | ✅ / ✅ | ✅ / — |
| Fuel cost per trip and month | — | ✅ |
| Monthly stats, fill-ups, records, average since new | — | ✅ |
| Own service history | ✅ | not yet |
| Route recording via the car's Bluetooth | ✅ | — (iOS can't reliably detect it in the background) |
| Map | ✅ 2D/3D with chargers (OpenStreetMap / NOBIL) | car position (Apple Maps) |
| EV trip planner with charging stops | ✅ | not yet |
| Weather and forecast | ✅ | not yet |
| Notifications | ✅ | ✅ (timing decided by iOS) |
| Home-screen widget | ✅ | not yet |
| Watch app | ✅ Wear OS | not yet (Apple Watch) |
| In-car app | ✅ Android Auto | — (CarPlay needs an Apple entitlement this project can't get) |
| App lock with fingerprint/code | ✅ | Face ID before unlock and horn |
| Languages | English, French, German, Spanish, Norwegian | English, Greek |
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

- LionCar talks only to the brand's servers (sign-in, car data, remote commands) and to Apple Maps. There is no LionCar
  server and nothing is collected.
- Sign-in tokens, the remote-control state and your security code are kept in the iPhone's **Keychain**, only on this
  device (not synced to iCloud). Car data, trips and settings stay in the app.
- Your password is only ever typed on the brand's own sign-in page; LionCar never sees it.
- The client IDs in `Core/Sources/LionCore/StellantisConfigsData.swift` are the brand apps' public ones, the same as in
  LionFlow and the Home Assistant integration — not anyone's personal keys.
- The test data in `Core/Tests/LionCoreTests/Fixtures` is made up (`scripts/make_fixtures.py`); no real car's data is
  in this repository.

## For developers

- `Core/` — the car logic (sign-in, API, status and trip parsing, one-time codes, MQTT remote control, stats, tags,
  warnings) as a plain Swift package. It builds and is tested on Linux: `cd Core && swift test`.
- `Sources/LionCar/` — the SwiftUI app.
- `translations/<language>.json` — translations. `scripts/extract_strings.py Sources/LionCar` lists the app's texts;
  `scripts/make_strings.py` builds the iOS files from the JSON.
- `design/make_icon.py` — draws the app icon.

## Licence

GPL-3.0 — see `LICENSE`. LionCar is based on LionFlow by thocubeat (GPL-3.0); credits and third-party licences are in
`NOTICE.md`.
