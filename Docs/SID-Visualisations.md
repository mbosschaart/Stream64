# SID visualisations

## Modular structure and rendering

Keep each new visualisation's view/effect implementation in its own Swift file
under `Sources/Stream64/Views`. Share analysis, topology and rendering plumbing
in Models and Rendering; do not grow the main view switch into an effect library.

The twelve generative effects use `SIDGenerativeRenderer`. Spectrum Analyzer,
3D Bar Field, Colorful Waveform, SID Showcase, 3D Waterfall and Spectrogram use
`SIDPerformanceGPU`, shared between standalone windows and Club Mode. Other
instrument panels use SwiftUI GPU composition via `drawingGroup`; their layout,
text and path preparation remain CPU work. FFT and SID analysis remain CPU work.
Do not wrap native MTKView surfaces in a SwiftUI drawing group.

Music Compo renders all sixteen scenes directly into Metal textures. No live
ImageRenderer snapshot, CGImage conversion or image-to-texture upload belongs in
its frame loop. Artwork and caption atlases are uploaded once per GPU; dynamic
inputs are numeric uniforms, samples and spectrum history. Standalone Metal
surfaces cap resolution and allow two frames in flight, with a 30 fps target
reduced to 15 under video pressure. These limits also protect the main stream.

## Adaptive mono and multi-SID presentation

`SIDPlaybackMetadata` records the original uploaded SID header's required chip
addresses only after successful playback. Generation tokens reject stale
completion. New playback, reset, reboot, power off, disk boot and disconnect
clear metadata; mounting a disk alone does not. Remote-path SID playback has no
local header and remains unknown. External playback changes cannot reliably be
detected while connected.

Settings offers Auto (SID file), Force single SID and Show all configured SIDs.
Auto matches tune addresses to configured chips. Unknown/unmatched metadata
preserves configured channels rather than guessing from temporary silence.

Oscilloscope, ADSR Envelope, Mixer Console, Piano Roll, Piano Keyboard, Voice
Lineup, VU Meter Bank, Register Activity, ADSR Knobs, Pulse Width, Control Bits,
SID Dashboard and Filter Curve display participating chips only. Abstract modes
mirror unused configured channels from active chips for presentation. Aggregate
FFT displays continue to show actual post-mix audio. No visual mirroring changes
raw registers, synthesis or playback routing.

Topology supports chip arrays and Metal uniforms carry nine voices, preparing
for three-SID presentation. This does not add end-to-end three-SID discovery or
hardware routing. Voice Lineup owns proportional fullscreen scaling; other
instrument panels use the shared sizing rules without double scaling.

## Cycling modes

Club Mode replaces KAOS mode with new visualisations and GPU-optimised rendering.
It shuffles all active individual scenes, with random 0.5–3 second cuts.
After 4–8 regular cuts it alternates two scenes five times at 0.2 seconds each.
Burst revisits do not consume the shuffled deck. KAOS is excluded from menus,
restoration and cycling, while its Swift implementation and assets remain.

Music Compo overlays visualisations directly onto the live C64 video stream,
turning static SID player screens into music-reactive shows. It uses the same timing with the twelve generative effects plus 3D Bar
Field, SID Showcase, Colorful Waveform and Spectrum Analyzer. Its engine-needs
union keeps the required FFT/history data available across cuts. It observes the
existing video stream without opening another stream or replacing the main
viewer's callback.

Effects render at the incoming PAL/NTSC video resolution. The GPU blends them
with C64 video before the selected video filter, scaling and CRT screen boundary,
so the result fits inside the bezel. The saved C64 video-opacity setting ranges
from 0–100%. The overlaid toolbar hides after two seconds of mouse inactivity,
returns on movement and stays visible during slider editing. Main-viewer capture
and recording are independent of this composition window.

## Artwork and presentation

SID Showcase (formerly SID Slideshow, retaining the old persisted identifier)
shows computer, floppy drive, tape, disk, joystick and 1702 monitor together.
Voice assignments rotate every four seconds; distortion, pulsing and coloured
echoes respond to the assigned voice. All six textures display upright. There is
no top title; individual captions identify the current SID and voice.

Signal Collage and retained KAOS select artwork for the connected hardware:
Ultimate 64-family devices use the Ultimate 64 logo, while C64 Ultimate uses its
own logo. Register Activity distinguishes repeated writes from value changes;
fullscreen typography and indicators scale with the view. Piano Keyboard retains
natural white/black-key proportions. Vector Flow uses brighter colours and Pulse
Vortex responds more strongly to bass and attacks.

## Playback handoff

Before launching converted PSID64 playback, conversion completes first. The app
then resets the native player, waits 200 ms for the firmware reset handler,
applies SID routing, refreshes engine configuration and uploads/runs the PRG.
This consumes the native player's transient skip-reset state before the PRG's
reset applies the new routing. Routing failures propagate for converted playback;
older native SID playback retains its best-effort header compatibility.

## Validation and limits

The suite covers adaptive topology, overrides, stale playback completion,
three-SID presentation inputs, routing call order/failure, cycling decks, GPU
scene output at PAL/NTSC sizes, blending and video filters. Showcase tests render
actual Metal output at landscape, portrait and fullscreen sizes; previews verify
upright artwork and captions without a top title.

The final full run, including the Showcase correction, executed 239 tests,
with eight fixture-dependent skips and no failures. Live mono-to-multi-SID hardware playback and sustained
stream performance remain unverified. Render tests do not establish that stream
hiccups are eliminated. Release 0.130b packages these changes for Apple Silicon and Intel Macs.
