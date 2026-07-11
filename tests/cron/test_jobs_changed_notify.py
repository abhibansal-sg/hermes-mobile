"""Tests for on_jobs_changed wiring (Phase 4F.1).

After a store mutation via the consumer surfaces (model tool / CLI / REST), the
active scheduler provider's on_jobs_changed() must be invoked so an external
provider (Chronos) re-provisions/cancels. The built-in's no-op default means
the default path is unchanged.
"""

import pytest
from fastapi import HTTPException


@pytest.fixture
def temp_home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    yield tmp_path


def test_notify_helper_calls_provider_on_jobs_changed(monkeypatch):
    """cron.scheduler._notify_provider_jobs_changed resolves the provider and
    calls on_jobs_changed exactly once."""
    import cron.scheduler_provider as sp
    import cron.scheduler as sched

    calls = []

    class Spy(sp.CronScheduler):
        @property
        def name(self):
            return "spy"

        def start(self, stop_event, **kw):
            pass

        def on_jobs_changed(self):
            calls.append(1)

    monkeypatch.setattr(sp, "resolve_cron_scheduler", lambda: Spy())
    sched._notify_provider_jobs_changed()
    assert calls == [1]


def test_notify_helper_swallows_provider_errors(monkeypatch):
    """A provider that raises in on_jobs_changed must not propagate into the
    caller (best-effort notify)."""
    import cron.scheduler_provider as sp
    import cron.scheduler as sched

    class Boom(sp.CronScheduler):
        @property
        def name(self):
            return "boom"

        def start(self, stop_event, **kw):
            pass

        def on_jobs_changed(self):
            raise RuntimeError("kaboom")

    monkeypatch.setattr(sp, "resolve_cron_scheduler", lambda: Boom())
    sched._notify_provider_jobs_changed()  # must not raise


def test_builtin_notify_is_harmless(monkeypatch):
    """With the built-in provider (default), notify is a no-op and never
    raises."""
    import cron.scheduler as sched
    # default resolution → built-in; just assert it doesn't blow up.
    sched._notify_provider_jobs_changed()


def test_tool_create_notifies_provider(temp_home, monkeypatch):
    """Creating a job via the cronjob tool path invokes on_jobs_changed."""
    import cron.scheduler as sched
    calls = []
    monkeypatch.setattr(sched, "_notify_provider_jobs_changed",
                        lambda: calls.append("changed"))

    from tools.cronjob_tools import cronjob
    import json

    out = json.loads(cronjob(action="create", prompt="echo hi", schedule="every 5m", name="w"))
    assert out["success"] is True
    assert calls == ["changed"]


def test_tool_remove_notifies_provider(temp_home, monkeypatch):
    """Removing a job via the tool path invokes on_jobs_changed."""
    import json
    from tools.cronjob_tools import cronjob

    created = json.loads(cronjob(action="create", prompt="x", schedule="every 5m", name="r"))
    jid = created["job_id"]

    import cron.scheduler as sched
    calls = []
    monkeypatch.setattr(sched, "_notify_provider_jobs_changed",
                        lambda: calls.append("changed"))

    out = json.loads(cronjob(action="remove", job_id=jid))
    assert out["success"] is True
    assert calls == ["changed"]


@pytest.fixture()
def isolated_dashboard_profiles(tmp_path, monkeypatch):
    """Give dashboard profile discovery an isolated default home plus one profile."""
    from hermes_cli import profiles

    default_home = tmp_path / ".hermes"
    profiles_root = default_home / "profiles"
    worker_home = profiles_root / "worker_alpha"

    for home in (default_home, worker_home):
        (home / "cron").mkdir(parents=True, exist_ok=True)
        (home / "config.yaml").write_text("model: test-model\n", encoding="utf-8")

    monkeypatch.setenv("HERMES_HOME", str(default_home))
    monkeypatch.setattr(profiles, "_get_default_hermes_home", lambda: default_home)
    monkeypatch.setattr(profiles, "_get_profiles_root", lambda: profiles_root)
    return {"default": default_home, "worker_alpha": worker_home}


def _spy_dashboard_notify(monkeypatch, calls):
    import cron.scheduler as sched

    def notify():
        from cron import jobs as cron_jobs
        from hermes_constants import get_hermes_home

        calls.append({
            "home": get_hermes_home(),
            "jobs_file": cron_jobs.JOBS_FILE,
        })

    monkeypatch.setattr(sched, "_notify_provider_jobs_changed", notify)


def _assert_worker_notify(calls, worker_home):
    assert calls == [{
        "home": worker_home,
        "jobs_file": worker_home / "cron" / "jobs.json",
    }]


@pytest.mark.asyncio
@pytest.mark.parametrize("mutation", ["create", "update", "pause", "resume", "trigger", "delete"])
async def test_dashboard_cron_mutations_notify_selected_profile_provider(
    isolated_dashboard_profiles,
    monkeypatch,
    mutation,
):
    from hermes_cli import web_server

    calls = []
    _spy_dashboard_notify(monkeypatch, calls)

    if mutation == "create":
        await web_server.create_cron_job(
            web_server.CronJobCreate(
                prompt="dashboard create",
                schedule="every 5m",
                name="dashboard-create",
            ),
            profile="worker_alpha",
        )
    else:
        job = web_server._call_cron_for_profile(
            "worker_alpha",
            "create_job",
            prompt=f"dashboard {mutation}",
            schedule="every 5m",
            name=f"dashboard-{mutation}",
        )
        calls.clear()

        if mutation == "update":
            await web_server.update_cron_job(
                job["id"],
                web_server.CronJobUpdate(updates={"name": "dashboard-updated"}),
                profile="worker_alpha",
            )
        elif mutation == "pause":
            await web_server.pause_cron_job(job["id"], profile="worker_alpha")
        elif mutation == "resume":
            web_server._call_cron_for_profile("worker_alpha", "pause_job", job["id"])
            await web_server.resume_cron_job(job["id"], profile="worker_alpha")
        elif mutation == "trigger":
            await web_server.trigger_cron_job(job["id"], profile="worker_alpha")
        elif mutation == "delete":
            await web_server.delete_cron_job(job["id"], profile="worker_alpha")

    _assert_worker_notify(calls, isolated_dashboard_profiles["worker_alpha"])


@pytest.mark.asyncio
async def test_dashboard_blueprint_instantiate_notifies_selected_profile_provider(
    isolated_dashboard_profiles,
    monkeypatch,
):
    import cron.blueprint_catalog as blueprint_catalog
    from hermes_cli import web_server

    calls = []
    _spy_dashboard_notify(monkeypatch, calls)
    monkeypatch.setattr(blueprint_catalog, "get_blueprint", lambda key: {"key": key})
    monkeypatch.setattr(
        blueprint_catalog,
        "fill_blueprint",
        lambda blueprint, values: {
            "prompt": "blueprint create",
            "schedule": "every 5m",
            "name": "blueprint-create",
        },
    )

    await web_server.instantiate_blueprint(
        web_server.AutomationBlueprintInstantiate(blueprint="test-blueprint", values={}),
        profile="worker_alpha",
    )

    _assert_worker_notify(calls, isolated_dashboard_profiles["worker_alpha"])


@pytest.mark.asyncio
async def test_dashboard_cron_missing_job_does_not_notify_provider(
    isolated_dashboard_profiles,
    monkeypatch,
):
    from hermes_cli import web_server

    calls = []
    _spy_dashboard_notify(monkeypatch, calls)

    with pytest.raises(HTTPException) as exc:
        await web_server.update_cron_job(
            "missing-job",
            web_server.CronJobUpdate(updates={"name": "nope"}),
            profile="worker_alpha",
        )

    assert exc.value.status_code == 404
    assert calls == []


def test_dashboard_profile_notify_is_best_effort(isolated_dashboard_profiles, monkeypatch):
    import cron.scheduler as sched
    from hermes_cli import web_server

    monkeypatch.setattr(
        sched,
        "_notify_provider_jobs_changed",
        lambda: (_ for _ in ()).throw(RuntimeError("notify failed")),
    )

    job = web_server._call_cron_for_profile(
        "worker_alpha",
        "create_job",
        prompt="best effort",
        schedule="every 5m",
        name="best-effort",
        notify_provider_on_success=True,
    )

    assert job["name"] == "best-effort"
