from __future__ import annotations

import base64
import json
import os

import pytest

from push_gateway.settings import Settings


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def _base_env(monkeypatch) -> None:
    for name in tuple(os.environ):
        if name.startswith("HPG_"):
            monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("HPG_TOKEN_MASTER_KEY_B64", _b64(b"m" * 32))
    monkeypatch.setenv("HPG_CAPABILITY_PEPPER_B64", _b64(b"p" * 32))
    monkeypatch.setenv("HPG_REQUIRE_APNS", "false")
    monkeypatch.setenv("HPG_DEVELOPMENT_REGISTRATION_TOKEN", "explicit-dev-token")


def test_token_keyring_file_rejects_symlink(monkeypatch, tmp_path) -> None:
    _base_env(monkeypatch)
    target = tmp_path / "token-keyring.json"
    target.write_text(json.dumps({"1": _b64(b"k" * 32)}))
    target.chmod(0o600)
    link = tmp_path / "token-keyring-link.json"
    link.symlink_to(target)
    monkeypatch.delenv("HPG_TOKEN_MASTER_KEY_B64")
    monkeypatch.setenv("HPG_TOKEN_MASTER_KEYS_FILE", str(link))

    with pytest.raises(ValueError, match="could not be securely read"):
        Settings.from_env()


def test_activation_keyring_file_rejects_hardlink(monkeypatch, tmp_path) -> None:
    _base_env(monkeypatch)
    original = tmp_path / "activation-keyring.json"
    original.write_text(json.dumps({"current": _b64(b"a" * 32)}))
    original.chmod(0o600)
    hardlink = tmp_path / "activation-keyring-hardlink.json"
    os.link(original, hardlink)
    monkeypatch.setenv("HPG_HUB_ACTIVATION_PRIVATE_KEYS_FILE", str(hardlink))
    monkeypatch.setenv("HPG_HUB_ACTIVATION_KEY_ID", "current")

    with pytest.raises(ValueError, match="exactly one hard link"):
        Settings.from_env()


def test_apns_private_key_file_rejects_group_or_other_mode(
    monkeypatch, tmp_path
) -> None:
    _base_env(monkeypatch)
    private_key = tmp_path / "apns-key.p8"
    private_key.write_text("test-private-key")
    private_key.chmod(0o640)
    monkeypatch.setenv("HPG_APNS_KEY_PATH", str(private_key))

    with pytest.raises(ValueError, match="owner-only permissions"):
        Settings.from_env()


def test_secure_apns_private_key_file_is_loaded(monkeypatch, tmp_path) -> None:
    _base_env(monkeypatch)
    private_key = tmp_path / "apns-key.p8"
    private_key.write_text("test-private-key")
    private_key.chmod(0o600)
    monkeypatch.setenv("HPG_APNS_KEY_PATH", str(private_key))

    assert Settings.from_env().apns_key_pem == "test-private-key"
