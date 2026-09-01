# Ganzfeld

An Apple Vision Pro app for monocular color experiments: one eye sees normal
camera passthrough while the other eye is treated with a custom RGB color —
either as an opaque color surface or as an additive/subtractive overlay on
top of passthrough.

Useful for ganzfeld-style perceptual experiments, binocular rivalry demos,
and color adaptation experiments.

## How it works

visionOS does not allow per-eye content through RealityKit, so the app uses
**CompositorServices + Metal** in a *mixed-immersion* `ImmersiveSpace`. The
renderer draws a fullscreen triangle amplified across both stereo views:

- The **untreated eye** is written as `(0, 0, 0, 0)` — fully transparent, so
  the system compositor shows unmodified camera passthrough.
- The **treated eye** is written with a premultiplied-alpha color chosen per
  mode. The compositor blends the layer over passthrough as
  `result = layer.rgb + (1 − layer.a) × passthrough`.

### Modes

Given color `C` (RGB sliders) and intensity `k`:

| Mode | Layer output (premultiplied) | Result seen by the treated eye |
|---|---|---|
| Solid | `(k·C, 1)` | Opaque color surface, passthrough fully replaced |
| Additive | `(k·C, 0)` | `passthrough + k·C` — exact additive light |
| Subtractive | `(k·(1−C), k)` | `(1−k)·passthrough + k·(1−C)` — darkens toward the complement |

**Note on subtractive:** true per-channel subtraction (`passthrough − k·C`)
is impossible on visionOS because apps cannot read passthrough pixels and
the system compositor only supports premultiplied-alpha "source-over"
blending, which cannot produce negative contributions. The subtractive mode
approximates a physical color filter by blending passthrough toward the
complement of the chosen color (e.g. subtracting red pulls the image toward
cyan while darkening it).

## Controls

- **Start/Stop Overlay** — opens/closes the mixed immersive space. The
  control window stays visible and adjustable while the overlay runs.
- **Treated eye** — Left or Right (stereo view 0 = left, view 1 = right).
- **Mode** — Solid / Additive / Subtractive.
- **R / G / B sliders** — the custom color (shown as 0–255 and hex).
- **Intensity** — effect strength from 0 to 100%.

All controls take effect live while the overlay is running.

## Requirements

- Xcode 16 or later
- visionOS 2.0+ (Metal rendering with passthrough requires visionOS 2's
  mixed-immersion Metal support)
- A physical Apple Vision Pro is strongly recommended — the simulator
  renders a single view and shows no real passthrough, so the per-eye
  behavior can only be evaluated on device.

## Build & run

Open `Ganzfeld.xcodeproj` in Xcode, select your device (or the visionOS
simulator), set your development team under Signing & Capabilities if
needed, and run. No special entitlements are required: the app uses only
`WorldTrackingProvider` for the device pose (no authorization prompt) and
never accesses camera imagery.

## Caveats

- Hands may "punch through" the solid surface in the treated eye — that is
  system passthrough compositing behavior for upper limbs.
- If the immersive space is closed with the Digital Crown, the app detects
  the invalidated renderer and resets the Start/Stop button state.
- Prolonged monocular color stimulation can cause strong afterimages and
  temporary interocular color differences; take breaks.
