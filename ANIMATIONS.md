# Animation notes: Isle vs Atoll

Method: observed only. Atoll 2.3.3 was run and screen-recorded (`screencapture -v`, region around the notch, ~60 fps
when the picture changes) over a solid gray cover so nothing personal was captured. Frames were measured with a small
script (island silhouette height and width per frame) and a few were looked at. No Atoll code, binaries or assets were read.
Isle was recorded and measured the same way, so the numbers below compare like with like.

## What Atoll does (measured)

| Motion | Measured behavior |
|---|---|
| Collapsed live activity | Cover on the left of the notch, equalizer bars on the right, pill widens about 40 pt per side. |
| Open (click) | Height 34 → 200 pt. 37% at +75 ms, 65% at +125 ms, 84% at +175 ms, 95% at +225 ms. Peaks at 201 (about 0.5% overshoot) at +330 ms, rests at 199–200 by +500 ms. Reads as a critically damped spring, response about 0.3 s, damping about 0.9. |
| Shape morph | Width and height grow together (width reaches full size slightly before height). Top corners flare outward into the menu bar, bottom corners round to about 24 pt. |
| Content on open | Shape first. The cover from the collapsed pill slides and grows to the left column while the equalizer fades; the expanded controls fade in around 70–80% of the height at low opacity and reach full opacity as the shape settles. Content never appears before the shape. |
| Close | Starts about 0.1 s after the cursor leaves. 50% at +90 ms, 95% at +250 ms, settles at +340 ms. No overshoot: it never dips below the notch height. |
| Tab switch | One strong first frame then an exponential decay to rest in about 0.45 s (content cross-fades and slides a few points). |
| Track change | Weaker, longer motion than a tab switch: about 0.55 s of small changes (artwork and text cross-fade). |

## What Isle does now (measured the same way)

| Motion | Isle value | Measured |
|---|---|---|
| Open | `Motion.expand` response 0.33, damping 0.90 | 95% at +175 ms, monotonic (no visible overshoot), full at about +300 ms |
| Close | `Motion.collapse` response 0.34, damping 1.0, collapse delay 0.18 s | 50% at +70 ms, 95% at +190 ms, rests at +340 ms, no dip |
| Content in | fade/scale 0.94 → 1 with an 80 ms delay, 240 ms; no blur (blur was costly and not needed) | follows the shape |
| Content out | fade 120 ms, before the shape finishes | |
| Tab switch | `Motion.tabResize` 0.34 / 0.88, 220 ms cross-fade with a 14 pt slide | about 0.42 s |
| Track change | 450 ms ease, artwork spring 0.45 / 0.80 | |
| Frame pacing | one new frame every 16–17 ms through open, close and tab switches | no dropped frames seen |

All values live in `Sources/IsleCore/Motion.swift`. Settings > Animations offers presets (Smooth is the Atoll-matched
default; Snappy, Bouncy, Minimal), a speed slider, and a switch per group. Reduce Motion replaces everything with a 150 ms fade.

## Remaining differences (honest list)

- Atoll's opening content stagger (cover flying from the pill into the left column) is not reproduced: in Isle the pill's cover fades out and the expanded cover fades in.
- Atoll has about 0.5% overshoot on open; Isle's open is monotonic.
- Atoll's default trigger is click; I could only measure its click behavior. Isle's default is hover (120 ms delay), so the first 120 ms differ by design.
- Not recorded for Atoll: device connection pop-up (needs a real device), drag-to-notch expansion, play/pause icon swap, lyric line change. Isle's values for those were chosen by feel and are unmatched.
- `screencapture` only stores frames that change, so very small differences (a few points over a few frames) are below what these measurements can see.
