from __future__ import annotations

import asyncio
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient

from conftest import FakeAPNs, FakeVerifier
from push_gateway.app import create_app
from push_gateway.settings import Settings
from push_gateway.storage import DatabaseStore
from push_gateway.work_pool import BoundedWorkPool, WorkPoolSaturated


def _settings() -> Settings:
    return Settings(
        database_url="sqlite:///:memory:",
        token_master_key=b"m" * 32,
        capability_pepper=b"p" * 32,
        apple_app_id="TEAM.ai.hermes.app",
        require_apns=False,
        database_max_concurrency=1,
    )


def test_database_pool_overload_is_explicit_and_non_queuing(monkeypatch) -> None:
    settings = _settings()
    store = DatabaseStore(settings)
    app = create_app(
        settings=settings,
        store=store,
        verifier=FakeVerifier(),
        apns_sender=FakeAPNs(),
    )
    started = threading.Event()
    release = threading.Event()

    def blocked_ready() -> bool:
        started.set()
        assert release.wait(5)
        return True

    monkeypatch.setattr(store, "ready", blocked_ready)
    with TestClient(app) as client, ThreadPoolExecutor(max_workers=1) as executor:
        first_future = executor.submit(client.get, "/readyz")
        assert started.wait(2)
        overloaded = client.get("/readyz")
        assert overloaded.status_code == 503
        assert overloaded.headers["retry-after"] == "1"
        assert overloaded.json()["error"]["code"] == "database_capacity_exhausted"
        assert not first_future.done()
        release.set()
        assert first_future.result(timeout=5).status_code == 200


def test_cancelled_database_call_keeps_admission_until_worker_exits() -> None:
    async def scenario() -> None:
        pool = BoundedWorkPool(1, thread_name_prefix="test-db")
        started = threading.Event()
        release = threading.Event()

        def blocked() -> str:
            started.set()
            assert release.wait(5)
            return "finished"

        task = asyncio.create_task(pool.run(blocked))
        try:
            assert await asyncio.to_thread(started.wait, 2)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            with pytest.raises(WorkPoolSaturated):
                await pool.run(lambda: "must-not-queue")
            release.set()
            while True:
                try:
                    result = await pool.run(lambda: "next")
                except WorkPoolSaturated:
                    await asyncio.sleep(0)
                    continue
                break
            assert result == "next"
        finally:
            release.set()
            await asyncio.gather(task, return_exceptions=True)
            await pool.close()

    asyncio.run(scenario())
