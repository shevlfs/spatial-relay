# Spatial Relay

[![CI](https://github.com/shevlfs/spatial-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/shevlfs/spatial-relay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Spatial Relay is a macOS menu-bar app that routes audio from Spotify Desktop through an Apple playback API that supports Spatialize Stereo. It is intended for AirPods models with Spatial Audio support.

```text
Spotify -> Core Audio process tap -> stereo Float32 PCM ring buffer
        -> AVSampleBufferAudioRenderer -> current output device
```

The app runs in the menu bar and has no Dock icon. Closing its panel does not stop an active relay.

## Requirements

- Apple silicon Mac
- macOS 14.2 or later
- Spatial Audio-capable AirPods
- Spotify Desktop (`com.spotify.client`)
- Xcode 16.4 or later when building from source

## Install

Prebuilt Apple silicon packages are available on the [Releases page](https://github.com/shevlfs/spatial-relay/releases). Release builds are ad-hoc signed and are not notarized. For a normal Gatekeeper-trusted build, compile the app with your own Apple development identity.

To build locally:

1. Clone the repository.
2. Open `SpatialRelay.xcodeproj` in Xcode.
3. Select the **SpatialRelay** scheme and your Mac.
4. Choose a Development Team if Xcode requests one.
5. Run the app.

## Use

1. Connect your AirPods and select them as the Mac's output.
2. Start playback in Spotify.
3. Open Spatial Relay from its waveform icon in the menu bar.
4. Click **Start relay**.
5. Approve **System Audio Recording** access when macOS asks.
6. Open the macOS Sound or AirPods menu and select **Fixed** or **Head Tracked** under Spatial Audio.

Stop the relay before intentionally changing output devices. If the output device changes during playback, the relay stops and restores Spotify's direct output. Start it again to use the new device. Use **Quit Spatial Relay** from the ellipsis menu to close the app.

## Audio and privacy

The relay accepts stereo, native-endian 32-bit floating-point PCM from Core Audio and submits Float32 PCM at the output device's nominal sample rate. It does not add lossy encoding, sample-rate conversion, normalization, EQ, or gain changes. Spotify's own source quality and normalization settings still apply.

Capture uses a device-stream process tap for the selected output. This keeps the tap tied to the output stream's format and clock; using a mixdown tap caused recurring glitches on Bluetooth headphones even when both reported the same nominal sample rate.

Audio remains in a bounded in-memory buffer. It is not written to disk, sent over the network, or collected as telemetry. Spotify's original output is muted only while the process tap is active. Normal stop, quit, and failure paths restore direct output.

The playback buffer targets 40 ms of audio, with a 4 ms pump interval. The panel shows audio queued in the capture buffer and renderer; it does not measure Bluetooth or device latency. A short audio burst that cannot fill the target buffer starts after an 80 ms wait.

Spatial Audio mode changes can briefly reconfigure the renderer. Spatial Relay gives those changes a five-second recovery window, flushes and rebases the render timeline, and keeps only recent captured audio when resuming. Recovery may cause a brief gap, but avoids carrying a long delay into playback. The relay stops safely if the output does not recover.

## Development

Run the unit tests from the command line:

```sh
xcodebuild \
  -project SpatialRelay.xcodeproj \
  -scheme SpatialRelay \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

CI runs the unit tests on an Intel macOS runner, then analyzes and cross-builds the arm64 Release target. Tags matching `vMAJOR.MINOR.PATCH` also run the tests on a native arm64 runner, build an ad-hoc signed app, verify it, and publish a ZIP and SHA-256 checksum to GitHub Releases.

The hosted test suite cannot exercise the System Audio Recording prompt, Spotify playback, AirPods routing, or the Spatial Audio menu. Changes to those paths should also be checked on a physical Mac.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Security reports are covered by [SECURITY.md](SECURITY.md).

## License

Spatial Relay is open source under the [MIT License](LICENSE).

Spotify, AirPods, Spatial Audio, macOS, and Apple are trademarks of their respective owners. This project is independent and is not affiliated with, endorsed by, or sponsored by Spotify or Apple.
