# Soreno

Native macOS speech-to-text. Runs entirely on your machine — no cloud, no API keys, no data leaves your device.

Powered by [NVIDIA Parakeet TDT 0.6B](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) running on Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).

## Features

- **Native macOS app** — lightweight Swift menu bar app, no Electron, no Python
- **English-first today** — current launch surface focuses on fast English dictation
- **Push-to-talk** — hold the Globe (fn) key to record, release to transcribe and paste
- **Fast and accurate** — Parakeet TDT 0.6B runs on Apple Neural Engine via CoreML
- **Types into any app** — transcribed text is pasted directly into the active application
- **Dynamic waveform** — floating pill shows a live audio waveform while recording
- **Smart formatting built in** — on-device cleanup improves punctuation, numbers, and structure
- **Fully local** — everything runs on-device, nothing is sent to the cloud

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1 or later recommended for Neural Engine)

## Install

### Build from source

```bash
git clone https://github.com/adnanjpg/Soreno.git
cd Soreno
chmod +x build.sh
./build.sh
```

This builds `Soreno.app` in the `dist/` directory. Copy it to `/Applications/`:

```bash
cp -r dist/Soreno.app /Applications/
```

### First launch

On first launch, Soreno will download the Parakeet model (~200MB). This only happens once.

## Usage

1. Launch Soreno — a microphone icon appears in the menu bar
2. Grant **Input Monitoring** and **Microphone** permissions when prompted
3. Open any text field (TextEdit, browser, Slack, etc.)
4. **Hold the Globe (fn) key** — a floating waveform pill appears at the bottom of the screen
5. Speak naturally
6. **Release the Globe key** — your speech is transcribed and typed into the active app

## Permissions

Soreno needs two macOS permissions:

| Permission | Why | Where to grant |
|---|---|---|
| **Input Monitoring** | Globe (fn) key detection | System Settings > Privacy & Security > Input Monitoring |
| **Microphone** | Audio capture | System Settings > Privacy & Security > Microphone |

Both are prompted automatically on first use.

## Architecture

```
Soreno/
  App/
    SorenoApp.swift              — @main SwiftUI MenuBarExtra entry point
    AppState.swift               — Central orchestrator
  Audio/
    AudioCaptureService.swift    — AVAudioEngine mic capture (16kHz mono)
    VoiceActivityDetector.swift  — RMS energy-based speech segmentation
  Transcription/
    WhisperService.swift         — FluidAudio / Parakeet TDT wrapper
  Input/
    GlobeKeyMonitor.swift        — CGEvent tap for Globe (fn) key
    HotkeyManager.swift          — Push-to-talk / toggle-mute modes
    TextInserter.swift           — Clipboard + CGEvent Cmd+V paste
  UI/
    MenuBarView.swift            — Menu bar dropdown
    RecordingPillView.swift      — Dynamic waveform visualization
    RecordingPillWindow.swift    — Floating NSPanel overlay
    SettingsView.swift           — Settings form
  Config/
    AppConfig.swift              — @AppStorage-backed settings
    Permissions.swift            — Permission checks
  Utilities/
    SoundEffects.swift           — Start/stop audio cues
```

## How it works

1. Globe (fn) key press detected via CGEvent tap (Input Monitoring permission)
2. AVAudioEngine captures microphone audio, resampled to 16kHz mono
3. Voice activity detection segments speech using RMS energy thresholds
4. Each speech segment is transcribed by Parakeet TDT via CoreML on Apple Neural Engine
5. Transcribed text is inserted into the active app via clipboard + simulated Cmd+V

## Tech stack

| Component | Technology |
|---|---|
| Language | Swift |
| UI | SwiftUI MenuBarExtra + NSPanel |
| STT model | NVIDIA Parakeet TDT 0.6B v3 |
| Inference | CoreML / Apple Neural Engine via FluidAudio |
| Audio | AVAudioEngine |
| Hotkey | CGEvent tap (Input Monitoring) |
| Text insertion | CGEvent keyboard simulation |
| Config | @AppStorage (UserDefaults) |

## License

[MIT](LICENSE)

The NVIDIA Parakeet TDT model is licensed under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).
