# Third-party notices

LionCar is licensed under the GNU General Public License v3.0 (see `LICENSE`).

## LionFlow — GPL-3.0
LionCar is an iPhone port of [LionFlow](https://github.com/thocubeat/lionflow) by thocubeat, an Android app under
the GNU General Public License v3.0. The car logic in `Core/` (sign-in, API calls, status and trip parsing, powertrain
detection) is translated from LionFlow's Kotlin code, and `Core/Sources/LionCore/StellantisConfigsData.swift` is
generated from LionFlow's `stellantis_configs.json`.

## homeassistant-stellantis-vehicles — MIT
LionFlow's Stellantis sign-in, API and MQTT command flow, and the sign-in configs, are based on
[homeassistant-stellantis-vehicles](https://github.com/andreadegiovine/homeassistant-stellantis-vehicles).

```
MIT License

Copyright (c) 2023

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## psa_car_controller — GPL-3.0
The one-time-password generator for remote commands (coming to LionCar) is a port of the OTP code in
[psa_car_controller](https://github.com/flobz/psa_car_controller) by Florian Bezannier (GPL-3.0), via LionFlow.

## Data and services
- Maps: Apple Maps (MapKit).
