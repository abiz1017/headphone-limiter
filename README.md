# Headphone Limiter

A macOS menu bar app that caps how loud your headphones can get.

- **Limit per output.** Pick a maximum in dB below full volume. Headphones are detected automatically; any output can be switched on or off by hand.
- **Rescaled volume range.** Instead of pulling the volume slider back, the app attenuates the audio itself, so the volume keys run from mute all the way up to your limit.
- **Limit in dB SPL.** For the Mac's own headphone jack the app reads the DAC's full-scale voltage from the hardware. Combined with your headphones' sensitivity it shows the limit as an absolute level, for example `−29 dB · ≤ 90 dB SPL`.
- **Model lookup.** Search 536 headphones and 270 DACs/amps by name to fill in sensitivity, impedance and output voltage. External DACs (USB or Bluetooth) are matched by device name when possible.

## Requirements

- macOS 14.2 or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`), for Swift 5.9+

## Build and run

```sh
git clone <this repository>
cd headphone-limiter
./build.sh --install      # builds and copies HeadphoneLimiter.app to /Applications
open /Applications/HeadphoneLimiter.app
```

Without `--install` the app is left in `build/HeadphoneLimiter.app`.

On first launch macOS asks for permission to record system audio. The rescaled volume range needs it, because audio headed for your headphones passes through the app. If you decline, turn off "Rescale the volume range" and the app pulls the volume slider back instead. The app is signed ad hoc, so macOS asks again after every rebuild.

The app lives in the menu bar (headphones icon). Opening it again from Finder or Spotlight shows the same controls in a window.

## Setting it up

1. Plug in your headphones and open the app.
2. Under "Maximum volume", search for your headphone model, or type its sensitivity from the spec sheet (dB/V, or dB/mW plus impedance).
3. Move the slider until the dB SPL figure is where you want it.

## Diagnostics

```sh
/Applications/HeadphoneLimiter.app/Contents/MacOS/HeadphoneLimiter --status          # outputs and the jack's DAC mode
/Applications/HeadphoneLimiter.app/Contents/MacOS/HeadphoneLimiter --lookup "hd 600" # search the model database
```

## Limitations

- **If the app crashes or is force-quit while rescaling, audio plays at the raw hardware volume**, which can be above your limit. A normal Quit lowers the volume to the limit first.
- The dB SPL figure is for a full-scale sine wave and rests on manufacturers' claimed specs, not measurements.
- The jack's voltage is read on Macs whose codec reports its output mode (MacBook Pro 2021 and later, and other recent Macs). Elsewhere, and for headphones with a built-in amplifier such as most Bluetooth headphones, there is no dB SPL figure; the limit in dB still works.
- Outputs without a software volume control (HDMI and DisplayPort monitors, for example) can't be limited.

## Data

Model data: [The Phone Path](https://thephonepath.com/) (CC BY 4.0), from
[temirowski/headphone-amp-database](https://github.com/temirowski/headphone-amp-database).
To refresh it: `Tools/make-database.py <path to a checkout of that repository>`.
