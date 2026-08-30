"""Thin wrappers around the local STT engines. Each exposes `.name` and
`.transcribe(wav_path) -> str`. Models load once (lazily) and are reused.

If a library isn't installed the engine reports unavailable and is skipped.
These call signatures track current mlx-whisper / parakeet-mlx / transformers;
if a version differs, tweak the `transcribe` methods — that's the only coupling.
"""
from __future__ import annotations

import atexit
import os
import shutil
import subprocess
import tempfile

# Must be set before torch is first imported (CohereTranscribeEngine): lets an
# op that MPS doesn't implement run on the CPU instead of raising.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


class WhisperEngine:
    name = "whisper"

    def __init__(self, repo: str = "mlx-community/whisper-small.en-mlx"):
        self.repo = repo
        self._mod = None

    @property
    def available(self) -> bool:
        try:
            import mlx_whisper  # noqa: F401
            return True
        except Exception:
            return False

    def transcribe(self, wav_path: str) -> str:
        if self._mod is None:
            import mlx_whisper
            self._mod = mlx_whisper
        out = self._mod.transcribe(wav_path, path_or_hf_repo=self.repo)
        return out["text"].strip()


class ParakeetEngine:
    name = "parakeet"

    def __init__(self, repo: str = "mlx-community/parakeet-tdt-0.6b-v2"):
        self.repo = repo
        self._model = None

    @property
    def available(self) -> bool:
        try:
            import parakeet_mlx  # noqa: F401
            return True
        except Exception:
            return False

    def transcribe(self, wav_path: str) -> str:
        if self._model is None:
            from parakeet_mlx import from_pretrained
            self._model = from_pretrained(self.repo)
        result = self._model.transcribe(wav_path)
        # parakeet-mlx returns an object with `.text`.
        return getattr(result, "text", str(result)).strip()


_TMP_AUDIO_DIR: str | None = None


def _as_16k_mono(wav_path: str):
    """Return the clip as a 1-D float32 array at 16 kHz. The gold set is already
    16 kHz mono, so this is normally a plain read; anything else is converted
    with ffmpeg into a *copy* in a temp dir (removed at exit) — the source file
    is never touched."""
    global _TMP_AUDIO_DIR
    import soundfile as sf

    info = sf.info(wav_path)
    if info.samplerate != 16000 or info.channels != 1:
        if _TMP_AUDIO_DIR is None:
            _TMP_AUDIO_DIR = tempfile.mkdtemp(prefix="stt-bench-16k-")
            atexit.register(shutil.rmtree, _TMP_AUDIO_DIR, ignore_errors=True)
        converted = os.path.join(_TMP_AUDIO_DIR, os.path.basename(wav_path))
        if not os.path.exists(converted):
            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-y", "-i", wav_path,
                 "-ac", "1", "-ar", "16000", "-f", "wav", converted], check=True)
        wav_path = converted
    audio, _ = sf.read(wav_path, dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return audio


class CohereTranscribeEngine:
    """Cohere Transcribe (CohereLabs/cohere-transcribe-03-2026): a 2B conformer
    encoder-decoder, run through transformers' native `CohereAsr*` classes on
    torch. Prefers MPS (bf16); if MPS fails at load or on a clip it reloads on
    CPU (fp32) and retries — slow is acceptable, crashing is not.

    Clips longer than the feature extractor's `max_audio_clip_s` (35 s) are
    chunked by the processor and the pieces are re-joined in `decode`, per the
    model card. Needs its own venv: see requirements-cohere-transcribe.txt.
    """
    name = "cohere-transcribe"
    sample_rate = 16000

    def __init__(self, repo: str = "CohereLabs/cohere-transcribe-03-2026",
                 device: str = "auto", language: str = "en",
                 max_new_tokens: int = 256):
        self.repo = repo
        self.language = language
        self.max_new_tokens = max_new_tokens
        self._requested_device = device
        self.device: str | None = None   # actual device once loaded
        self.dtype: str | None = None
        self.commit: str | None = None   # model revision actually loaded
        self._processor = None
        self._model = None

    @property
    def available(self) -> bool:
        try:
            import torch  # noqa: F401
            from transformers import CohereAsrForConditionalGeneration  # noqa: F401
            return True
        except Exception:
            return False

    def load(self, device: str | None = None):
        import torch
        from transformers import AutoProcessor, CohereAsrForConditionalGeneration

        device = device or self._requested_device
        if device == "auto":
            device = "mps" if torch.backends.mps.is_available() else "cpu"
        dtype = torch.bfloat16 if device == "mps" else torch.float32
        if self._processor is None:
            self._processor = AutoProcessor.from_pretrained(self.repo)
        self._model = None
        model = CohereAsrForConditionalGeneration.from_pretrained(self.repo, dtype=dtype)
        self._model = model.to(device).eval()
        self.device, self.dtype = device, str(dtype).replace("torch.", "")
        self.commit = getattr(model.config, "_commit_hash", None)
        return self

    def _run(self, audio) -> str:
        import torch

        proc, model = self._processor, self._model
        inputs = proc(audio, sampling_rate=self.sample_rate,
                      language=self.language, return_tensors="pt")
        chunk_index = inputs.get("audio_chunk_index")
        inputs = inputs.to(model.device, dtype=model.dtype)  # casts float tensors only
        with torch.inference_mode():
            out = model.generate(**inputs, max_new_tokens=self.max_new_tokens)
        text = proc.decode(out, skip_special_tokens=True,
                           audio_chunk_index=chunk_index, language=self.language)
        if isinstance(text, list):
            text = text[0]
        return text.strip()

    def transcribe(self, wav_path: str) -> str:
        audio = _as_16k_mono(wav_path)
        if self._model is None:
            self.load()
        try:
            return self._run(audio)
        except Exception as ex:
            if self.device != "mps":
                raise
            print(f"  [{self.name}] MPS failed ({type(ex).__name__}: {str(ex)[:160]})"
                  " — reloading on CPU (fp32) and retrying")
            self._model = None
            import gc, torch
            gc.collect()
            torch.mps.empty_cache()
            self.load("cpu")
            return self._run(audio)


def available_engines():
    engines = [WhisperEngine(), ParakeetEngine(), CohereTranscribeEngine()]
    return [e for e in engines if e.available]
