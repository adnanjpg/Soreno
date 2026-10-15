# Soreno - Roadmap

A living document of planned features and improvements. Items will be tackled incrementally over time.

**Overall status (2026-04-18):** ✅ Core roadmap and recording UX follow-up items implemented.

**Current launch surface (2026-04-27):**
- Soreno currently ships as an **English-first** product.
- Multi-language transcription remains a **future roadmap item** and is not exposed in the current app UI.
- Smart post-processing remains **enabled internally** but its controls are hidden from the current user-facing app.

## Branding Decision

**Date:** 2026-04-22

- Selected product/domain name: **Soreno**
- Chosen primary domain: **soreno.app**
- Domain purchased and reserved.
- Codebase renamed from **Listen** to **Soreno**.
- GitHub repository renamed to **adnanjpg/Soreno**.

---

## 0. Product North Star (Voice Layer for AI Work)

**Status (2026-04-22):** 🚧 Active direction

**Vision:** Build the easiest way to talk to AI and listen to AI across apps, so people can run work hands-free while agents do execution in the background.

**Positioning:** Not a dictation utility for developers only. A general productivity layer for anyone using AI at work: operators, founders, support teams, students, marketers, managers, and individual professionals.

**Core promise:** One voice interface that works everywhere users already work (agent tools, chat apps, docs, browsers, and meetings), instead of being locked to one assistant or one platform.

**North-star use cases:**
- Talk instructions to multiple AI agents while away from the keyboard (walking, commuting, cooking, chores).
- Listen to agent outputs, summaries, and next actions as spoken audio.
- Dictate and read in communication tools (Slack, Teams, Discord, email, docs) with the same quality and flow.
- Keep a continuous speak -> execute -> listen loop without requiring constant typing and screen focus.

**Product principles:**
- **Cross-app first** - Works with any focused text surface and selected text path where macOS allows.
- **Voice quality first** - Better dictation and read-aloud quality than default OS assistants.
- **Low-friction control** - Reliable shortcuts, selection reading, clipboard fallback, and menu-bar entry points.
- **Privacy-respectful by default** - Local-first processing where possible and transparent model/data behavior.
- **Human-in-the-loop friendly** - Built for supervising agents, not replacing user judgment.

## 1. Smart Post-Processing & Formatting

**Status (2026-04-27):** 🚧 Future launch phase

**Approach:** All post-processing is handled by a local LLM — no rule-based pipeline. The raw transcription from Parakeet is passed to the model, which reformats and corrects it in one shot.

**Model:** Llama 3.2 1B (4-bit quantized, ~0.7 GB RAM). Runs locally on Apple Silicon via MLX. If quality is insufficient, can be swapped to Llama 3.2 3B with no code changes.

**How it works:**
1. Parakeet transcribes speech to raw text (existing pipeline, unchanged).
2. Raw text is sent to Llama 3.2 1B with a system prompt containing the user profile, custom dictionary, and formatting instructions.
3. The model returns cleaned, formatted text.
4. Formatted text is inserted into the active app (existing insertion pipeline, unchanged).

**Features:**
- **Number conversion** - Convert spoken numbers to digits (e.g. "five hundred" -> "500").
- **Markdown-aware output** - Produce properly formatted paragraphs, lists, and structure instead of plain flat text.
- **Context-aware word correction** - Fix domain-specific misrecognitions based on context (e.g. "cloud" -> "Claude" when in a coding context).
- **Custom dictionary** - A user-maintained word list for names, technical terms, and jargon that the default model gets wrong. Passed to the LLM as part of the system prompt.
- **System prompt / user profile** - A configurable description of who the user is and what they do. The LLM reads this to understand context and make smarter corrections.
- **Correction memory** - Learn from past misrecognitions over time. Stored persistently and injected into the system prompt automatically.

## 2. Multi-Language Support

**Status (2026-04-17):** ✅ Completed

**Approach:** Keep Parakeet for English (best-in-class for its size), add Whisper for all other languages in a later launch phase. The multi-language path remains implemented internally but is not part of the current user-facing product surface.

**Models:**
- **English:** Parakeet TDT 0.6B v2 (existing, unchanged).
- **Other languages:** Whisper small (244M, ~0.2 GB) or Whisper medium (769M, ~0.5 GB). Supports 99 languages.

**How it will work when re-enabled:**
1. User selects language in the UI (or leaves it on English by default).
2. When a non-English language is selected, Parakeet is unloaded and Whisper is loaded.
3. Switching back to English unloads Whisper and reloads Parakeet.
4. Memory footprint stays the same as today — only one STT model in memory at a time.

**Notes:**
- There is a brief loading delay when switching languages (one-time per switch).
- The post-processing LLM (Llama 3.2 1B) already handles multiple languages, so no changes needed there.

## 3. Desktop App Interface

**Status (2026-04-17):** ✅ Completed

**Approach:** Native macOS app built with SwiftUI. Design should follow Apple Human Interface Guidelines — look and feel like a first-party Apple app. The menu bar popover remains for quick access; the desktop window is for settings and management.

**Design principles:**
- Native SwiftUI controls, no custom widgets where system ones exist.
- SF Symbols for all icons.
- System colors, typography, and spacing throughout.
- macOS-standard patterns: sidebar navigation, Settings window (⌘,), toolbar controls.

**Window contents:**
- **System prompt / user profile editor** - Text area to describe who you are and what you do.
- **Custom dictionary** - Table view to add/edit/remove words and their corrections.
- **Correction memory** - View and manage auto-learned corrections.
- **Language selector** - Pick active language, triggers model swap.
- **Hotkey configuration** - Already partially exists in menu bar, moves here.
- **General settings** - Toggle features on/off, model preferences, etc.

**Immediate implementation steps (desktop branch):**
- [x] Wire language selection to real runtime model swapping (Parakeet for English, Whisper for non-English).
- [x] Add first-launch behavior that opens the desktop Settings window and walks users through feature toggles.
- [x] Add JSON import/export for custom dictionary and correction memory management.

## 4. Text-to-Speech (Read Aloud)

**Status (2026-04-17):** ✅ Completed

**Approach:** Two TTS engines available — Apple built-in (always available, no download) and a local model for enhanced/dialect support. User chooses which to enable.

**Engines:**
- **Apple Built-in (AVSpeechSynthesizer)** - Free, no download. Supports multiple languages in formal/standard accents. Good default.
- **Enhanced TTS (Piper or similar)** - Local model, optional download. Supports custom voices and dialect pronunciation (e.g. Syrian Arabic). Heavier but higher quality.

**How it works:**
1. User highlights text anywhere on screen.
2. Triggers read-aloud via keyboard shortcut or right-click context menu.
3. App reads the selected text using whichever TTS engine is active.

**New follow-up items (2026-04-21):**
- [ ] **[MEDIUM]** Fix menu-bar selection bug specifically for the menu item path: when the menu is open and "Read Selected Text" is clicked, always read the current system text selection (same behavior as the keyboard shortcut path).

**Read-selected accessibility plan (2026-04-22):**
- [ ] **[HIGH]** Implement a primary global shortcut path for "Read Selected Text" so the feature works even when an app does not expose `Services`.
- [ ] **[HIGH]** Add a clipboard fallback path: when direct selection access fails, read clipboard text via a fast copy-then-read flow.
- [ ] **[LOW]** Keep macOS Services/Quick Action integration as a secondary path where supported by the target app.
- [ ] **[MEDIUM]** Add a guaranteed menu-bar action (`Read Clipboard`) as an always-available entry point.
- [ ] **[LOW]** Document the macOS platform constraint in onboarding/help text: third-party apps cannot reliably inject a custom context-menu item next to Copy/Paste across all apps.

## 5. Model & Feature Management (First-Launch Experience)

**Status (2026-04-17):** ✅ Completed

**Approach:** On first launch, the app opens the desktop Settings window instead of just the menu bar. Users toggle only the features they want — models are downloaded on-demand, not bundled.

**Principles:**
- **Minimal by default** - Only Parakeet (English STT) is required and ships with the app. Everything else is opt-in.
- **Download on enable** - Toggling a feature on triggers its model download with a progress indicator.
- **No auto-delete** - Toggling a feature off disables it but keeps the model on disk. A separate "Delete model" button lets the user reclaim space explicitly.
- **First-launch onboarding** - Opens Settings window, walks user through available features and lets them pick what to enable.

**Toggleable features and their models:**
| Feature | Model | Download size |
|---------|-------|--------------|
| English STT | Parakeet TDT 0.6B v2 | Required (bundled) |
| Smart Post-Processing | Llama 3.2 1B (4-bit) | ~0.7 GB |
| Multi-Language STT | Whisper small/medium | ~0.2-0.5 GB |
| Enhanced TTS (Dialects) | Piper / similar | TBD |
| Apple TTS | Built-in | No download |

**Implementation status (2026-04-17):**
- Added backend `ModelFeatureManager` with a feature/model catalog and per-model install state tracking.
- Added persisted feature toggles and first-launch onboarding state in app config.
- Added "download on enable" model provisioning flow with install progress and explicit delete API for optional models.
- Updated app state wiring so optional bridge services are enabled only when the feature is on and the model is installed.
- Added desktop Settings model-management UI for install/retry/delete with live state display.
- Added remote download manifests for optional models (Llama, Whisper, Piper voice files).

**Follow-up items (2026-04-23):**
- [ ] **[HIGH]** Hide model names from all user-facing UI. Settings, onboarding, and feature toggles should show only feature names (e.g. "Multi-Language STT", "Smart Post-Processing") — never model identifiers like architecture names, parameter counts, or repo names. Goal: make it harder for someone to reverse-engineer which models power the app.
- [x] **[HIGH]** Hide smart post-processing controls from the current user-facing app while keeping the feature enabled internally.
- [x] **[HIGH]** Remove manual install/reinstall/delete actions from the current user-facing app UI; optional components are managed automatically in the background.

## 6. Recording Subtitle + History UX

**Status (2026-04-18):** ✅ Completed

**Goal:** Make live recording feedback and transcript browsing feel polished and scannable.

**Items:**
- [x] Add live subtitles under the recording voice component while recording.
- [x] Show subtitles in a rolling window of 5 words at a time; as new words arrive, oldest visible words should drop off (stack-style behavior).
- [x] Add smooth disappearance/transition animations for outgoing subtitle words (fade/slide quality comparable to modern live-transcription UIs).
- [x] Persist up to 20 recent transcript paragraphs inside the app as a list view.
- [x] In that list, render each row as a 2-line preview.
- [x] When a row is opened/selected, show the full paragraph text.

## 7. Recording + History Follow-up UX

**Status (2026-04-21):** 🚧 Planned

**Goal:** Finish remaining UX gaps around post-recording feedback and per-entry detail context.

**Items:**
- [ ] **[HIGH]** Add a loading indicator in the voice component after recording stops when language-model processing is active/enabled. Especially important for non-English (Whisper) transcription which takes noticeably longer — the pill should show a processing/loading state instead of disappearing after the user releases the shortcut.
- [ ] **[MEDIUM]** In History detail, show the selected entry's full text and the full prompt associated with that specific entry.

**Acceptance criteria:**
- If language-model processing is running after recording, users see explicit loading state in the voice component until processing finishes/fails.
- Opening any history entry shows complete selected text (not preview only).
- History detail exposes the full prompt used for that entry (entry-level prompt snapshot, not only current global prompt).

## 8. Menu Bar Quick Controls + Cancel Processing

**Status (2026-04-26):** 🚧 Planned

**Goal:** Make menu-bar usage fast enough that users can change language and post-processing behavior without opening Settings, and let them interrupt slow in-flight processing so they can immediately speak again.

**Items:**
- [ ] **[HIGH]** When recording has stopped and transcription/post-processing is still loading, show a cancel action in the recording pill/loading state so users can abort the current processing job and immediately start a new recording.

**Acceptance criteria:**
- While the recording pill is in a loading/processing state, users can press a visible cancel control to stop the in-flight transcription/post-processing task.
- Cancel returns the app to a clean ready state: no stuck loading spinner, no stale recording state, and the next recording can begin immediately.

## 9. Release Packaging + App Update Pipeline

**Status (2026-04-27):** 🚧 Planned

**Goal:** Build signed macOS releases in a cloud environment on every tagged release (or selected branch/release event), generate a distributable DMG automatically, publish a stable download URL for the website/app, and support in-app update + restart flows.

**Items:**
- [ ] **[HIGH]** Set up a cloud macOS CI/CD pipeline that builds the app on GitHub-triggered events (at minimum: release tags; optionally: selected commits/branches).
- [ ] **[HIGH]** Archive the app, sign/notarize it in CI, and generate a distributable DMG artifact automatically.
- [ ] **[HIGH]** Publish release artifacts to a stable host/CDN path that can be linked from the website and referenced by the app.
- [ ] **[HIGH]** Integrate Sparkle app updates end-to-end, including appcast generation/signing and release publication from CI.
- [ ] **[MEDIUM]** Add an in-app "Restart to Update" / "Relaunch to Finish Update" flow so users can reliably apply downloaded updates.
- [ ] **[MEDIUM]** Decide release trigger policy: GitHub Release creation only vs tag pushes vs manual dispatch for pre-release/internal builds.
- [ ] **[MEDIUM]** Document required CI secrets and signing assets: Developer ID Application certificate, Developer ID Installer certificate if needed, notarization credentials, Sparkle signing key, and artifact host credentials.

**Acceptance criteria:**
- Creating a GitHub Release (or approved trigger event) produces a signed + notarized DMG without requiring the local machine.
- The website can point to a stable DMG URL that always resolves to the latest approved build or to versioned release URLs.
- The app can detect a newly published update, download it safely, and present a clear restart/relaunch path to finish applying it.

## 10. Bugs

**Status (2026-04-23):** 🚧 Active

### BUG-1: "Transcription failed, invalid audio data" error shown to user [HIGH]

- The app sometimes surfaces an error like "transcription failed, invalid audio data provided, must be at least one second."
- This message should be suppressed or handled gracefully — never shown to the user.

### BUG-2: Audio device switching breaks recording [HIGH]

- When connecting AirPods or another audio device mid-session, the recording UI appears to be active but does not actually record.
- Recording cannot be re-triggered after this happens.
- Root cause likely: the audio session/input device reference becomes stale when the system audio device changes.

### BUG-3: Recording on/off state mismatch [HIGH]

- The recording pill's visual state can become out of sync with the actual recording state.
- The pill may appear visible/on when recording is actually off (or vice versa).
- Pressing the hotkey should act as a reliable toggle: if the pill is visible (even incorrectly), the hotkey should dismiss it and ensure the actual state matches. In other words, the hotkey must always reconcile visual and actual state.

### BUG-4: Menu bar item appears selected but isn't [MEDIUM]

- When opening the menu bar popover, the middle item visually appears selected/highlighted even though it is not actually selected.
- Likely a SwiftUI list/button highlight state issue.

### BUG-5: Recording pill too wide [LOW]

- The recording pill has excessive horizontal padding, making it wider than it needs to be.
- Reduce padding to make it more compact.

### BUG-6: Post-processing leaks example text into user output [HIGH]

- When smart post-processing is enabled, the model can append or replace the user's actual sentence with unrelated example text such as: `"One thing I want is the upload button to be bigger."`
- Likely root cause: prompt/example leakage from the post-processing bridge prompt, where that exact sentence exists as a few-shot example.
- The post-processing stage must never inject unrelated example content into the cleaned transcript.

### BUG-7: Hovered item explanation preview is too generic to ship [MEDIUM]

- The current hovered-item explanation preview often produces vague or repetitive output such as: `"This appears to be a scroll area. It is in T3 code alpha. In the T3 code alpha window, nearby context. Group, group, group, group, scroll area."`
- In practice, the feature does not identify the user's real target reliably enough in complex apps/editors, so the spoken explanation is usually not useful.
- The preview entry points are intentionally hidden for now until the metadata capture and explanation quality are materially better.

**What we tried (2026-04-28):**
- Added hovered accessibility snapshot capture using `AXUIElementCopyElementAtPosition`, plus role, title, description, help, value, identifier, parent trail, and window title extraction.
- Added a local Llama-based explanation pass via the existing Python bridge, with a short grounded prompt and strict output constraints.
- Added a rule-based fallback explanation path when the model output is weak or missing.
- Added read-aloud integration so the explanation could be spoken directly through the TTS pipeline.
- Verified that the feature works mechanically end-to-end, but the underlying accessibility metadata is still too coarse in many real apps, especially where the pointer lands on container views like scroll areas or generic groups.

**Next time we revisit it:**
- Prefer focused/selected/editor-owned UI elements over raw pointer-hit containers when possible.
- Add stronger filtering/ranking for generic roles like `group` and `scroll area`.
- Validate behavior in target apps/editors before re-enabling any user-facing shortcut or menu action.

## 11. Hotkey Defaults

**Status (2026-04-26):** 🚧 Planned

**Goal:** Make first-run recording feel more reliable by using a less collision-prone default shortcut.

**Items:**
- [ ] **[HIGH]** Change the default recording hotkey from **Globe/Fn** to **Left Option (`Left ⌥`)**.

**Acceptance criteria:**
- Fresh installs default to `Left ⌥` as the recording hotkey.
- Existing users keep their current saved hotkey (no forced override).
- UI labels and onboarding copy reflect the new default.
