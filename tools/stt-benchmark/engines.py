"""Thin wrappers around the local STT engines. Each exposes `.name` and
`.transcribe(wav_path) -> str`. Models load once (lazily) and are reused.

If a library isn't installed the engine reports unavailable and is skipped.
These call signatures track current mlx-whisper / parakeet-mlx; if a version
differs, tweak the two `transcribe` methods — that's the only coupling.
"""
from __future__ import annotations


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


def available_engines():
    engines = [WhisperEngine(), ParakeetEngine()]
    return [e for e in engines if e.available]
