# Ganzfeld

An Apple Vision Pro app for monocular color experiments: one eye sees normal
camera passthrough while the other eye is treated with a custom RGB color —
either as an opaque color surface or as an additive/subtractive overlay on
top of passthrough. A both-eyes mode treats the full visual field instead.

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

Given color `C` (the RGB sliders, converted from sRGB to linear light before
any math) and intensity `k`, where `Y(C)` is `C`'s Rec. 709 luminance:

| Mode | Layer output (premultiplied) | Result seen by the treated eye |
|---|---|---|
| Solid | `(k·C, k)` | `k·C + (1−k)·passthrough` — opaque color at 100%, cross-fading to passthrough below |
| Additive | `(k·C, 0)` | `passthrough + k·C` — exact additive light |
| Subtractive | `(0, k·Y(C))` | `(1−k·Y(C))·passthrough` — neutral attenuation weighted by the color's luminance |

In every mode, intensity 0% means untouched passthrough.

**Note on subtractive:** true per-channel subtraction (`passthrough − k·C`)
is impossible on visionOS: apps cannot read passthrough pixels, and the
system compositor's premultiplied-alpha "source-over" blend can only scale
all channels by one scalar alpha and add non-negative light. Any added
constant term can end up brighter than the passthrough behind it (which is
how an earlier version of this mode could *brighten* the treated eye), so
subtractive adds nothing and only attenuates: the chosen color sets *how
much* light is removed via its luminance — black removes nothing, white at
100% removes everything — and the result is never brighter than passthrough.
The hue of `C` cannot selectively filter matching wavelengths; for a colored
darkening effect, use Solid at partial intensity instead.

**Note on color values:** the sliders, swatch, and hex readout are
sRGB-encoded display values (what `#RRGGBB` normally means). They are
converted to linear before being handed to the shader, which writes linear
light to an sRGB render target — so the treated eye receives the same color
the swatch shows, and recorded hex values describe the actual stimulus.

## Controls

- **Start/Stop Overlay** — opens/closes the mixed immersive space. The
  control window stays visible and adjustable while the overlay runs.
- **Treated eye** — Left, Right, or Both (stereo view 0 = left, view 1 =
  right; Both treats the entire visual field).
- **Mode** — Solid / Additive / Subtractive.
- **R / G / B sliders** — the custom color (shown as 0–255 and hex).
- **Intensity** — effect strength from 0 to 100%; 0% is always "no effect"
  in every mode.

All controls take effect live while the overlay is running.

### Game controller UI toggle

With a paired game controller, pressing **Options/Menu** (or Create/Home)
hides the control window while the overlay runs, and summons it back —
useful for both-eyes or solid sessions where the floating window would
intrude on the visual field. PS VR2 Sense controllers pair with Apple
Vision Pro on visionOS 26 or later (Settings → Bluetooth); any standard
Bluetooth gamepad also works. The hide branch of the toggle is ignored
while the overlay is stopped or mid-transition, and if the overlay ends
while the window is hidden (Stop, or Digital Crown), the control window is
reopened automatically — both so the app is never left with zero scenes,
which would suspend it and cut off controller input.

## Requirements

- Xcode 16 or later
- visionOS 2.0+ (Metal rendering with passthrough requires visionOS 2's
  mixed-immersion Metal support); visionOS 26+ for PS VR2 Sense controller
  pairing (other Bluetooth gamepads work on visionOS 2)
- A physical Apple Vision Pro is strongly recommended — the simulator
  renders a single view and shows no real passthrough, so the per-eye
  behavior can only be evaluated on device. In the simulator the single
  view is always treated regardless of the eye selection, so the overlay
  is visible with the default settings.

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
  the invalidated renderer, resets the Start/Stop button state, and reopens
  the control window if it was hidden.
- Prolonged monocular color stimulation can cause strong afterimages and
  temporary interocular color differences; take breaks.
