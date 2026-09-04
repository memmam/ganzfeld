#!/usr/bin/env python3
"""Resolve a bootable visionOS simulator on the runner and print its UDID.

GitHub's macOS images ship visionOS runtimes, but which ones move with the
image and with Xcode's deprecation policy, so nothing here hardcodes a version
or a device name. If a runtime is present but no device exists for it, one is
created; if no runtime is present at all, the platform is downloaded.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys


def sh(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def version_key(identifier: str) -> tuple[int, ...]:
    """Sort key from a runtime identifier such as ...SimRuntime.xrOS-2-5."""
    digits = re.findall(r"\d+", identifier.rsplit(".", 1)[-1])
    return tuple(int(d) for d in digits) or (0,)


def is_vision_runtime(identifier: str) -> bool:
    tail = identifier.rsplit(".", 1)[-1].lower()
    return tail.startswith("xros") or tail.startswith("visionos")


def newest_device() -> str | None:
    devices = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "--json"))
    candidates = [
        (version_key(runtime), device["udid"], device["name"], runtime)
        for runtime, entries in devices.get("devices", {}).items()
        if is_vision_runtime(runtime)
        for device in entries
        if device.get("isAvailable", False)
    ]
    if not candidates:
        return None
    key, udid, name, runtime = max(candidates)
    print(f"Using {name} ({runtime})", file=sys.stderr)
    return udid


def create_device() -> str | None:
    """Make a device for an installed runtime that has none."""
    runtimes = json.loads(sh("xcrun", "simctl", "list", "runtimes", "--json"))
    available = [
        r for r in runtimes.get("runtimes", [])
        if r.get("isAvailable") and is_vision_runtime(r["identifier"])
    ]
    if not available:
        return None
    runtime = max(available, key=lambda r: version_key(r["identifier"]))

    device_types = json.loads(sh("xcrun", "simctl", "list", "devicetypes", "--json"))
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
    vision_types = [
        d["identifier"] for d in device_types.get("devicetypes", [])
        if "vision" in d["identifier"].lower() or "Vision" in d.get("name", "")
    ]
    for identifier in vision_types:
        if supported and identifier not in supported:
            continue
        print(f"Creating a simulator for {runtime['identifier']}", file=sys.stderr)
        try:
            return sh(
                "xcrun", "simctl", "create", "ci-vision-pro", identifier, runtime["identifier"]
            ).strip()
        except subprocess.CalledProcessError:
            continue
    return None


def main() -> int:
    udid = newest_device() or create_device()
    if udid is None:
        print("No visionOS runtime on this runner; downloading it.", file=sys.stderr)
        subprocess.run(["xcodebuild", "-downloadPlatform", "visionOS"], check=False)
        udid = newest_device() or create_device()

    if udid is None:
        print(
            "::error::No visionOS simulator runtime is available on this runner "
            "and it could not be downloaded.",
            file=sys.stderr,
        )
        return 1

    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
