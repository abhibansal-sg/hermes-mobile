"""Regression: a desktop-touched session stored with billing_provider="custom" and
no base_url must NOT force the unresolvable "custom" provider into the resume
override (which made session.resume fail 5000 "No LLM provider configured" and the
iOS client never bind activeRuntimeId). It falls back to the configured global
provider. A REAL custom endpoint (with base_url) is preserved.
"""
import json
from tui_gateway import server


def test_drops_unresolvable_custom_provider_without_base_url():
    row = {"id": "s", "model": "claude-opus-4-8",
           "billing_provider": "custom", "model_config": ""}
    ov = server._stored_session_runtime_overrides(row)
    assert ov["model_override"]["model"] == "claude-opus-4-8"
    assert ov["model_override"]["provider"] is None, "custom-no-base_url must drop the provider"
    assert "provider_override" not in ov, "no provider_override -> resume uses the global provider"


def test_keeps_custom_provider_with_real_base_url():
    row = {"id": "s", "model": "m", "billing_provider": "custom",
           "model_config": json.dumps({"base_url": "http://127.0.0.1:9999"})}
    ov = server._stored_session_runtime_overrides(row)
    assert ov["model_override"]["provider"] == "custom"
    assert ov["model_override"]["base_url"] == "http://127.0.0.1:9999"
    assert ov["provider_override"] == "custom"


def test_keeps_standard_named_provider():
    row = {"id": "s", "model": "gpt-5.4", "billing_provider": "openai-codex", "model_config": ""}
    ov = server._stored_session_runtime_overrides(row)
    assert ov["model_override"]["provider"] == "openai-codex"
    assert ov["provider_override"] == "openai-codex"
