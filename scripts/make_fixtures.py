#!/usr/bin/env python3
"""Writes the made-up test data in Core/Tests/LionCoreTests/Fixtures: a fictional 48 V mild hybrid ("synthetic_mhev")
in the shape the Stellantis API uses. Every value is invented; none comes from a real car.

The figures are chosen so the tests mean something: the fuel counter uses an unusual unit (1 unit = 4 ml) like some
real cars, the tank falls from 40 % to 100 % between two trips (a fill-up), and one trip lost its connection."""
import json, os, sys
from datetime import datetime, timedelta

OUT = sys.argv[1] if len(sys.argv) > 1 else "Core/Tests/LionCoreTests/Fixtures"
HOME = (48.8566, 2.3522)        # Paris (start of every trip)
OTHER = (48.8920, 2.2380)       # La Défense
UNIT_L = 0.004                  # litres per fuel unit for this fictional car

def point(lat, lon): return {"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]}}
def iso(d): return d.strftime("%Y-%m-%dT%H:%M:%SZ")
def energies(level, rng): return [{"type": "Fuel", "subType": "FossilEnergy", "level": level, "autonomy": rng},
                                  {"type": "Electric", "subType": "ElectricEnergy"}]

# start (UTC), km, minutes, litres, level start→end, range start→end, connection lost
TRIPS = [
    ("2025-03-03 07:30", 18.0, 25, 1.08, 62, 59, 430, 410, False),
    ("2025-03-03 16:45", 18.2, 28, 1.20, 59, 56, 410, 400, False),
    ("2025-03-04 07:35", 60.0, 50, 3.30, 56, 48, 400, 330, False),
    ("2025-03-04 17:10", 58.0, 55, 3.48, 48, 40, 330, 280, False),
    ("2025-03-05 12:00", 3.0, 8, 0.24, 40, 40, 280, 280, True),
    ("2025-03-06 08:00", 12.0, 20, 0.84, 100, 100, 700, 690, False),
    ("2025-03-06 18:00", 25.0, 30, 1.45, 100, 97, 690, 670, False),
    ("2025-03-08 10:00", 80.0, 70, 4.40, 97, 87, 670, 600, False),
    ("2025-03-09 15:00", 9.5, 15, 0.76, 87, 86, 600, 590, False),
]

trips, mileage = [], 11_580.0
for i, (start, km, mins, liters, l0, l1, r0, r1, lost) in enumerate(TRIPS, 1):
    s = datetime.strptime(start, "%Y-%m-%d %H:%M")
    e = s + timedelta(minutes=mins)
    raw = round(liters / UNIT_L, 2)
    end = OTHER if i % 2 else HOME
    trips.append({
        "id": f"trip-{i}", "startedAt": iso(s), "stoppedAt": iso(e), "createdAt": iso(e), "updatedAt": iso(e),
        "duration": mins * 60, "distance": km, "done": True,
        "startEnergies": energies(l0, r0), "endEnergies": energies(l1, r1),
        "energyConsumptions": [{"type": "Fuel", "subType": "FossilEnergy", "consumption": raw,
                                "avgConsumption": round(raw / km * 100, 4)}],
        "kinetic": {"avgSpeed": round(km / (mins / 60), 2), "maxSpeed": 90 + i},
        "startMileage": round(mileage, 1),
        "faults": [{"fault": "DataLacking", "cause": "Connection"}] if lost else [],
        "startPosition": point(*HOME), "stopPosition": point(*end),
    })
    mileage += km

at = "2025-03-09T18:00:00Z"
status = {
    "createdAt": at, "updatedAt": at,
    "lastPosition": {**point(*HOME), "properties": {"createdAt": at, "heading": 90, "type": "Acquire", "signalQuality": 7, "fixStatus": "3D"}},
    "engines": [{"type": "Thermic", "extension": {"thermic": {"coolant": {"temp": 75.0}, "oil": {"temp": 20.0}, "air": {"temp": 20.0}}}, "createdAt": at}],
    "powertrain": {"createdAt": at, "status": "Stopped"},
    "ignition": {"createdAt": at, "type": "Stop"},
    "battery": {"voltage": 13.2, "createdAt": at},
    "privacy": {"createdAt": at, "state": "None"},
    "doorsState": {"createdAt": at, "lockedStates": ["Locked", "RearDoorsLocked"],
                   "opening": [{"identifier": d, "state": "Closed"} for d in ["Trunk", "Driver", "RearRight", "RearLeft", "Passenger", "RearWindow"]]},
    "lightingSystem": {"createdAt": at,
                       "turn": [{"direction": d, "position": p, "status": "Off"} for d in ["Left", "Right"] for p in ["Front", "Rear"]],
                       "fog": [{"direction": d, "position": p, "status": "Off"} for d in ["Left", "Right"] for p in ["Front", "Rear"]]},
    "service": {"createdAt": at, "type": "Unknown"},
    "safety": {"createdAt": at, "beltStatus": [{"belt": "Omission", "id": "belt-1"}, {"belt": "Omission", "id": "belt-2"}]},
    "environment": {"luminosity": {"createdAt": at, "day": False}, "air": {"createdAt": at, "temp": 14.5}},
    "drivingBehavior": {"createdAt": at, "mode": "Eco"},
    "odometer": {"createdAt": at, "mileage": 12000.0},
    "kinetic": {"createdAt": at, "acceleration": 0.0, "lateralAcceleration": 0.0, "speed": 0.0, "moving": False},
    "alarm": {"status": {"createdAt": at, "activation": "Active"}},
    "transmission": {"gearbox": {"mode": "Auto"}},
    # 180 000 units × 4 ml over 12 000 km = 6.0 l/100 km since new
    "energies": [
        {"createdAt": at, "type": "Fuel", "subType": "FossilEnergy", "level": 80.0, "autonomy": 560,
         "extension": {"fuel": {"consumptions": {"total": 180000.0, "instant": 5.8}}}},
        {"createdAt": at, "type": "Electric", "subType": "ElectricEnergy",
         "extension": {"electric": {"battery": {"load": {"createdAt": at, "residual": 400},
                                                "health": {"createdAt": at, "capacity": 97, "resistance": 100}},
                                    "charging": {"chargingRate": 0}}}},
    ],
    "energy": [
        {"createdAt": at, "updatedAt": at, "type": "Fuel", "level": 80.0, "autonomy": 560, "consumption": 5.8},
        {"createdAt": at, "updatedAt": at, "type": "Electric", "charging": {"chargingRate": 0},
         "battery": {"load": {"residual": 400}, "health": {"capacity": 97, "resistance": 100}}},
    ],
}
vehicle = {"id": "synthetic-vehicle", "vin": "VR3SYNTHETIC00001", "motorization": "Hybrid", "brand": "Peugeot",
           "pictures": ["https://example.invalid/car.png"], "_embedded": {"extension": {"branding": {"brand": "Peugeot"}}}}

os.makedirs(OUT, exist_ok=True)
for name, data in [("synthetic_mhev_status", status), ("synthetic_mhev_trips", trips), ("synthetic_mhev_vehicle", vehicle)]:
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        json.dump(data, f, indent=1)
print("wrote", OUT)
