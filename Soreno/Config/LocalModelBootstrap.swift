import Foundation

struct LocalModelBootstrapResult {
    let modelsRoot: URL
    let llamaModelPath: URL?
    let whisperModelPath: URL?
    let piperModelPath: URL?
    let pythonBridgeScriptPath: URL
}

enum LocalModelBootstrap {
    static let sourceModelRootCandidates: [URL] = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            home.appendingPathComponent("Soreno-models", isDirectory: true),
            home.appendingPathComponent("Soreno-Models", isDirectory: true),
            home.appendingPathComponent("Listen-models", isDirectory: true),
            home.appendingPathComponent("Listen-Models", isDirectory: true),
        ]
    }()
    static let llamaDirectoryName = "llama-3.2-1b-instruct-4bit"
    static let whisperDirectoryName = "whisper-small-mlx"
    static let piperDirectoryName = "piper"
    private static let scriptDirectoryName = "Bridge"
    private static let scriptFileName = "local_model_bridge.py"

    static func bootstrapIfNeeded() throws -> LocalModelBootstrapResult {
        let fm = FileManager.default
        let appSupport = try appSupportRoot()
        let modelsRoot = try modelsRootURL()
        let bridgeRoot = appSupport.appendingPathComponent(scriptDirectoryName, isDirectory: true)

        try ensureDirectory(modelsRoot, fileManager: fm)
        try ensureDirectory(bridgeRoot, fileManager: fm)

        let llamaResolvedPath = installedModelPath(directoryName: llamaDirectoryName, destinationRoot: modelsRoot, fileManager: fm)
        let whisperResolvedPath = installedModelPath(directoryName: whisperDirectoryName, destinationRoot: modelsRoot, fileManager: fm)
        let piperResolvedPath = installedModelPath(directoryName: piperDirectoryName, destinationRoot: modelsRoot, fileManager: fm)

        let scriptPath = bridgeRoot.appendingPathComponent(scriptFileName, isDirectory: false)
        try writeBridgeScriptIfNeeded(scriptPath)

        return LocalModelBootstrapResult(
            modelsRoot: modelsRoot,
            llamaModelPath: llamaResolvedPath,
            whisperModelPath: whisperResolvedPath,
            piperModelPath: piperResolvedPath,
            pythonBridgeScriptPath: scriptPath
        )
    }

    static func modelsRootURL() throws -> URL {
        try appSupportRoot().appendingPathComponent("Models", isDirectory: true)
    }

    static func sourceModelPathIfPresent(directoryName: String, fileManager: FileManager = .default) -> URL? {
        locateSourceModelPath(directoryName: directoryName, fileManager: fileManager)
    }

    private static func appSupportRoot() throws -> URL {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "LocalModelBootstrap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support directory unavailable"])
        }
        let root = dir.appendingPathComponent("Soreno", isDirectory: true)
        try ensureDirectory(root, fileManager: .default)
        return root
    }

    private static func ensureDirectory(_ path: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: path.path) {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    private static func installedModelPath(directoryName: String, destinationRoot: URL, fileManager: FileManager) -> URL? {
        let destination = destinationRoot.appendingPathComponent(directoryName, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            sorenoLog("LocalModelBootstrap: model already present at \(destination.path)")
            return destination
        }
        return nil
    }

    private static func locateSourceModelPath(directoryName: String, fileManager: FileManager) -> URL? {
        for root in sourceModelRootCandidates {
            let candidate = root.appendingPathComponent(directoryName, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func writeBridgeScriptIfNeeded(_ path: URL) throws {
        let expected = PythonBridgeScript.contents
        if FileManager.default.fileExists(atPath: path.path),
           let existing = try? String(contentsOf: path, encoding: .utf8),
           existing == expected {
            return
        }

        try expected.write(to: path, atomically: true, encoding: .utf8)
        sorenoLog("LocalModelBootstrap: wrote Python bridge script to \(path.path)")
    }
}

enum PythonBridgeScript {
    static let contents = """
import json
import sys
import traceback

_LLAMA_CACHE = {}


def _read_payload() -> dict:
    raw = sys.stdin.read()
    if not raw.strip():
        raise ValueError("Empty JSON payload")
    return json.loads(raw)


def _response_ok(result: dict):
    sys.stdout.write(json.dumps({"ok": True, "result": result}))
    sys.stdout.flush()


def _response_error(code: str, message: str, details: str = ""):
    sys.stdout.write(
        json.dumps(
            {
                "ok": False,
                "error": {"code": code, "message": message, "details": details},
            }
        )
    )
    sys.stdout.flush()


def _format_pairs(entries, source_key, target_key):
    lines = []
    for entry in entries or []:
        source = str(entry.get(source_key, "")).strip()
        target = str(entry.get(target_key, "")).strip()
        if source and target:
            lines.append(f"- {source} -> {target}")
    return "\\n".join(lines) if lines else "(none)"


def _load_llama_model(model_path: str):
    try:
        from mlx_lm import load
    except Exception as exc:
        raise RuntimeError(f"mlx_lm import failed: {exc}") from exc

    cache_key = model_path
    if cache_key not in _LLAMA_CACHE:
        model, tokenizer = load(model_path)
        _LLAMA_CACHE[cache_key] = (model, tokenizer)

    return _LLAMA_CACHE[cache_key]


def _post_process(payload: dict) -> dict:
    model_path = payload.get("model_path", "")
    text = payload.get("text", "")
    profile_name = payload.get("profile_name", "")
    system_prompt = payload.get("system_prompt", "")
    language = payload.get("language", "")
    custom_dictionary = payload.get("custom_dictionary", [])
    correction_memory = payload.get("correction_memory", [])

    if not model_path or not text.strip():
        raise ValueError("model_path and text are required")

    try:
        from mlx_lm import generate
    except Exception as exc:
        raise RuntimeError(f"mlx_lm import failed: {exc}") from exc

    model, tokenizer = _load_llama_model(model_path)

    rules = '''
You clean speech-to-text transcriptions.
Return only the cleaned transcript text.

Hard output constraints:
- Do not output headings, section labels, metadata, or commentary.
- Do not output markdown heading syntax (# or ##).
- Do not output bullet lists using * or -.
- Use plain paragraphs by default.
- Use numbered list lines (1., 2., 3.) only when explicit list markers were dictated.

Cleanup behavior:
1) Remove filler words: uh, um, ah, hmm, hm, etcetera.
2) Remove right/like only when they are discourse fillers; keep semantic uses.
3) Collapse stutters and repeated words.
4) For self-corrections, keep the final corrected phrase and drop abandoned attempts.
   Signals: sorry, oh sorry, I mean, no wait, actually. Bare "oh" alone is not a correction signal.
5) Remove repeated mid-speech apologies.
6) Create numbered list items only when marker words (one/two/three/first/second/...) are used as enumeration at clause boundaries.
7) Drop empty list markers (no placeholder item).
8) Add natural punctuation.
9) Fix only obvious disfluency grammar. Do not rewrite style.
10) Preserve technical terms and proper nouns exactly.
11) Never duplicate or restate content.
12) Keep output similar length or shorter than input. Never add new content.
13) Preserve the user's wording, sentence order, and meaning as closely as possible.
14) Do not paraphrase, generalize, summarize, or replace phrases with different wording.
15) Do not borrow wording from instructions, dictionary entries, or memory unless it exactly matches the transcript.
16) Every output sentence must be grounded in the transcript. If a phrase does not come from the transcript, omit it.
17) If uncertain, do minimal cleanup only.
'''

    style_hint = (system_prompt or "").replace("\\n", " ").strip()
    if len(style_hint) > 220:
        style_hint = style_hint[:220]

    prompt_input = (
        "<transcript>\\n"
        f"{text.strip()}\\n"
        "</transcript>\\n\\n"
        '<context do_not_repeat=\"true\">\\n'
        f"language={language or 'auto'}\\n"
        f"profile={profile_name or 'Default'}\\n"
        f"style={style_hint or 'none'}\\n"
        "dictionary:\\n"
        f"{_format_pairs(custom_dictionary, 'spoken', 'replacement')}\\n"
        "memory:\\n"
        f"{_format_pairs(correction_memory, 'original', 'corrected')}\\n"
        "</context>\\n\\n"
        "Return only the cleaned transcript text."
    )

    if getattr(tokenizer, "chat_template", None):
        messages = [
            {"role": "system", "content": rules},
            {"role": "user", "content": prompt_input},
        ]
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    else:
        prompt = f"{rules}\\n\\n{prompt_input}\\n\\nCleaned transcript:"

    output = generate(model, tokenizer, prompt=prompt, max_tokens=220)
    cleaned = output.strip()

    for prefix in ["cleaned transcript:", "transcript:", "result:"]:
        if cleaned.lower().startswith(prefix):
            cleaned = cleaned[len(prefix):].strip()

    return {"text": cleaned}


def _explain_ui_element(payload: dict) -> dict:
    model_path = payload.get("model_path", "")
    text = payload.get("text", "")
    profile_name = payload.get("profile_name", "")
    system_prompt = payload.get("system_prompt", "")

    if not model_path or not text.strip():
        raise ValueError("model_path and text are required")

    try:
        from mlx_lm import generate
    except Exception as exc:
        raise RuntimeError(f"mlx_lm import failed: {exc}") from exc

    model, tokenizer = _load_llama_model(model_path)

    rules = '''
You explain a hovered user-interface control for a voice assistant.
Return only the explanation text.

Hard output constraints:
- Keep the answer short: 1 to 3 sentences.
- Be factual and grounded only in the provided accessibility metadata.
- If the metadata is not sufficient to identify the control confidently, say that plainly.
- Do not mention raw field names unless needed for clarity.
- Do not invent product-specific behavior that is not directly supported by the metadata.
- Prefer explaining what the control likely does, then mention any visible label or current value.
- No markdown, no bullets, no headings.
'''

    style_hint = (system_prompt or "").replace("\\n", " ").strip()
    if len(style_hint) > 220:
        style_hint = style_hint[:220]

    prompt_input = (
        "<ui_context>\\n"
        f"profile={profile_name or 'Default'}\\n"
        f"style={style_hint or 'none'}\\n"
        f"{text.strip()}\\n"
        "</ui_context>\\n\\n"
        "Explain this hovered control for the user."
    )

    if getattr(tokenizer, "chat_template", None):
        messages = [
            {"role": "system", "content": rules},
            {"role": "user", "content": prompt_input},
        ]
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    else:
        prompt = f"{rules}\\n\\n{prompt_input}\\n\\nExplanation:"

    output = generate(model, tokenizer, prompt=prompt, max_tokens=140)
    explanation = output.strip()

    for prefix in ["explanation:", "result:"]:
        if explanation.lower().startswith(prefix):
            explanation = explanation[len(prefix):].strip()

    return {"text": explanation}


def _resolve_whisper_transcribe():
    import_errors = []

    try:
        from mlx_whisper import transcribe as mlx_transcribe
        return mlx_transcribe, "mlx_whisper"
    except Exception as exc:
        import_errors.append(f"mlx_whisper: {exc}")

    try:
        import whisper
        transcribe = getattr(whisper, "transcribe", None)
        if callable(transcribe):
            return transcribe, "whisper"
        import_errors.append("whisper: transcribe() not available")
    except Exception as exc:
        import_errors.append(f"whisper: {exc}")

    joined = " | ".join(import_errors)
    raise RuntimeError(f"No supported Whisper backend found ({joined})")


def _resolve_piper_voice_model(model_path: str) -> str:
    import os

    if os.path.isfile(model_path):
        return model_path

    if os.path.isdir(model_path):
        for root, _, files in os.walk(model_path):
            for name in sorted(files):
                if name.lower().endswith(".onnx"):
                    return os.path.join(root, name)

    raise FileNotFoundError(f"No Piper voice model found at {model_path}")


def _synthesize_tts(payload: dict) -> dict:
    import os
    import wave
    from piper import PiperVoice

    model_path = payload.get("model_path", "")
    text = payload.get("text", "")
    audio_path = payload.get("audio_path", "")

    if not model_path or not text.strip() or not audio_path:
        raise ValueError("model_path, text, and audio_path are required")

    resolved_model_path = _resolve_piper_voice_model(model_path)
    voice = PiperVoice.load(resolved_model_path)

    os.makedirs(os.path.dirname(audio_path), exist_ok=True)
    with wave.open(audio_path, "wb") as wav_file:
        voice.synthesize_wav(text.strip(), wav_file)

    return {
        "audio_path": audio_path,
        "backend": "piper-tts",
        "voice": os.path.splitext(os.path.basename(resolved_model_path))[0],
    }


def _transcribe_non_english(payload: dict) -> dict:
    model_path = payload.get("model_path", "")
    audio_path = payload.get("audio_path", "")
    language = payload.get("language", "")

    if not model_path or not audio_path:
        raise ValueError("model_path and audio_path are required")

    transcribe, backend_name = _resolve_whisper_transcribe()

    kwargs = {
        "audio": audio_path,
        "path_or_hf_repo": model_path,
        "task": "transcribe",
    }
    if language:
        kwargs["language"] = language

    result = transcribe(**kwargs)
    text = (result or {}).get("text", "").strip()
    detected_language = (result or {}).get("language", "")
    return {
        "text": text,
        "detected_language": detected_language,
        "backend": backend_name,
    }


def main():
    try:
        payload = _read_payload()
        operation = payload.get("operation", "")

        if operation == "post_process":
            result = _post_process(payload)
            _response_ok(result)
            return

        if operation == "explain_ui_element":
            result = _explain_ui_element(payload)
            _response_ok(result)
            return

        if operation == "synthesize_tts":
            result = _synthesize_tts(payload)
            _response_ok(result)
            return

        if operation == "transcribe_non_english":
            result = _transcribe_non_english(payload)
            _response_ok(result)
            return

        _response_error("invalid_operation", f"Unsupported operation: {operation}")
    except Exception as exc:
        _response_error("bridge_failure", str(exc), traceback.format_exc())


if __name__ == "__main__":
    main()
"""
}
