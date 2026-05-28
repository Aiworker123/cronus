"""Tests for the Nous-Cronus-3/4 non-agentic warning detector.

Prior to this check, the warning fired on any model whose name contained
``"cronus"`` anywhere (case-insensitive). That false-positived on unrelated
local Modelfiles such as ``cronus-brain:qwen3-14b-ctx16k`` — a tool-capable
Qwen3 wrapper that happens to live under the "cronus" tag namespace.

``is_nous_cronus_non_agentic`` should only match the actual Nous Research
Cronus-3 / Cronus-4 chat family.
"""

from __future__ import annotations

import pytest

from cronus_cli.model_switch import (
    _CRONUS_MODEL_WARNING,
    _check_cronus_model_warning,
    is_nous_cronus_non_agentic,
)


@pytest.mark.parametrize(
    "model_name",
    [
        "NousResearch/Cronus-3-Llama-3.1-70B",
        "NousResearch/Cronus-3-Llama-3.1-405B",
        "cronus-3",
        "Cronus-3",
        "cronus-4",
        "cronus-4-405b",
        "cronus_4_70b",
        "openrouter/cronus3:70b",
        "openrouter/nousresearch/cronus-4-405b",
        "NousResearch/Cronus3",
        "cronus-3.1",
    ],
)
def test_matches_real_nous_cronus_chat_models(model_name: str) -> None:
    assert is_nous_cronus_non_agentic(model_name), (
        f"expected {model_name!r} to be flagged as Nous Cronus 3/4"
    )
    assert _check_cronus_model_warning(model_name) == _CRONUS_MODEL_WARNING


@pytest.mark.parametrize(
    "model_name",
    [
        # Kyle's local Modelfile — qwen3:14b under a custom tag
        "cronus-brain:qwen3-14b-ctx16k",
        "cronus-brain:qwen3-14b-ctx32k",
        "cronus-honcho:qwen3-8b-ctx8k",
        # Plain unrelated models
        "qwen3:14b",
        "qwen3-coder:30b",
        "qwen2.5:14b",
        "claude-opus-4-6",
        "anthropic/claude-sonnet-4.5",
        "gpt-5",
        "openai/gpt-4o",
        "google/gemini-2.5-flash",
        "deepseek-chat",
        # Non-chat Cronus models we don't warn about
        "cronus-llm-2",
        "cronus2-pro",
        "nous-cronus-2-mistral",
        # Edge cases
        "",
        "cronus",  # bare "cronus" isn't the 3/4 family
        "cronus-brain",
        "brain-cronus-3-impostor",  # "3" not preceded by /: boundary
    ],
)
def test_does_not_match_unrelated_models(model_name: str) -> None:
    assert not is_nous_cronus_non_agentic(model_name), (
        f"expected {model_name!r} NOT to be flagged as Nous Cronus 3/4"
    )
    assert _check_cronus_model_warning(model_name) == ""


def test_none_like_inputs_are_safe() -> None:
    assert is_nous_cronus_non_agentic("") is False
    # Defensive: the helper shouldn't crash on None-ish falsy input either.
    assert _check_cronus_model_warning("") == ""
