#!/usr/bin/env python3
"""Lists the user-facing strings in Sources/LionCar the way SwiftUI looks them up (interpolations become %@ / %lld).
Usage: extract_strings.py SOURCES_DIR > keys.json"""
import json, os, re, sys

CALLS = r"(?<![A-Za-z_])(?:accessibilityLabel|Text|Label|Button|Toggle|Picker|Stepper|LabeledContent|Section|TextField|SecureField|ProgressView|DisclosureGroup|" \
        r"navigationTitle|confirmationDialog|alert|Marker|tile|row|notice|record|value|stat|bigButton|smallButton|L)"
START = re.compile(r"(?:" + CALLS + r"\(\s*|String\(localized:\s*)\"")

def literal(src, i):
    """The string literal starting at src[i] (just after the opening quote), allowing quotes inside \\( … )."""
    out, depth = "", 0
    while i < len(src):
        c = src[i]
        if depth == 0 and c == "\\" and src[i + 1] == "(":
            depth = 1; out += "\\("; i += 2; continue
        if depth == 0 and c == "\\":
            out += src[i:i + 2]; i += 2; continue
        if depth == 0 and c == '"':
            return out
        if depth:
            depth += {"(": 1, ")": -1}.get(c, 0)
        out += c; i += 1
    return out
INT_HINTS = ("Int(", ".count", "m.trips", "pct", "lowPct")
INT_EXPRS = {"m", "m / 60", "m % 60"}   # whole minutes in Fmt.duration

def key(lit):
    has_vars = "\\(" in lit
    out, i = "", 0
    while i < len(lit):
        if lit.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth:
                depth += {"(": 1, ")": -1}.get(lit[j], 0); j += 1
            expr = lit[i + 2:j - 1]
            is_int = (any(h in expr for h in INT_HINTS) and "formatted" not in expr and "Fmt." not in expr) or expr in INT_EXPRS
            out += "%lld" if is_int else "%@"
            i = j
        else:
            # SwiftUI writes a literal % as %% in keys that contain variables
            out += "%%" if (has_vars and lit[i] == "%") else lit[i]; i += 1
    return out.replace('\\"', '"')

# Texts that reach the screen through variables (car type, card titles, command labels and progress from the core)
EXTRA = ["48 V mild hybrid", "Plug-in hybrid", "Hybrid (type unknown)", "Electric", "Petrol / diesel", "Car",
         "Fuel / battery and range", "Locks and remote control", "Where the car is", "Odometer, service and more",
         "7 days", "30 days", "3 months", "1 year", "Flash lights", "Updating from the car",
         "Connecting…", "Sent — waiting for the car…", "Waking the car…", "Checking the car…", "Car received it",
         "Car didn't answer — trying again…", "Car was busy — trying again…", "Waiting for the car to report…",
         "Distance", "Fuel", "Cost", "Charges", "Fill-ups", "Sending…", "Driving now", "Engine on", "Driving now · %lld km/h"]
keys = {k: "extra" for k in EXTRA}
for root, _, files in os.walk(sys.argv[1]):
    for f in sorted(files):
        if f.endswith(".swift"):
            src = open(os.path.join(root, f)).read()
            for m in START.finditer(src):
                k = key(literal(src, m.end()))
                if re.search(r"[A-Za-z]{2}", k) and not k.startswith(("lioncar.", "com.")):
                    keys.setdefault(k, f)
json.dump(keys, sys.stdout, indent=1, ensure_ascii=False)
