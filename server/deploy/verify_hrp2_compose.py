#!/usr/bin/env python3
"""Live assertions for a freshly started HRP/2 CI Compose project."""

from __future__ import annotations

import base64
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit


REPOSITORY = Path(__file__).resolve().parents[2]
COMPOSE = (
    "docker",
    "compose",
    "-f",
    str(REPOSITORY / "server/compose.hrp2.yml"),
    "-f",
    str(REPOSITORY / "server/deploy/compose.hrp2.ci.yml"),
)
EXPECTED_SERVICES = {
    "caddy",
    "push-gateway",
    "push-gateway-db",
    "push-gateway-migrate",
    "relay-hub",
    "relay-hub-db",
    "relay-hub-migrate",
}


def compose(*arguments: str) -> str:
    result = subprocess.run(
        (*COMPOSE, *arguments),
        cwd=REPOSITORY,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def container_inspect(service: str) -> dict:
    container_id = compose("ps", "--all", "-q", service)
    if not container_id:
        raise AssertionError(f"Compose did not create {service}")
    result = subprocess.run(
        ("docker", "inspect", container_id),
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    if len(payload) != 1:
        raise AssertionError(f"unexpected inspect result for {service}")
    return payload[0]


def timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def successful_health_before(container: dict, deadline: datetime) -> bool:
    logs = container["State"].get("Health", {}).get("Log", [])
    return any(
        entry.get("ExitCode") == 0 and timestamp(entry["End"]) <= deadline
        for entry in logs
    )


def environment(container: dict) -> dict[str, str]:
    values: dict[str, str] = {}
    for item in container["Config"].get("Env", []):
        name, separator, value = item.partition("=")
        if separator:
            values[name] = value
    return values


def psql(service: str, user: str, database: str, query: str) -> str:
    return compose(
        "exec",
        "-T",
        service,
        "psql",
        "--no-psqlrc",
        "-v",
        "ON_ERROR_STOP=1",
        "-U",
        user,
        "-d",
        database,
        "-Atqc",
        query,
    )


def public_host(value: str) -> str:
    parsed = urlsplit(value if "://" in value else f"//{value}")
    return parsed.netloc or parsed.path


READY_PROBE = r"""
import json
import sys
from urllib.request import urlopen

with urlopen(f"http://127.0.0.1:{sys.argv[1]}/readyz", timeout=5) as response:
    payload = json.load(response)
    assert response.status == 200, response.status
    assert payload == {"status": "ready"}, payload
print(json.dumps(payload, sort_keys=True))
"""


PROXY_AND_WRITE_SMOKE = r"""
import base64
import json
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen

hub_host, push_host, enrollment_id = sys.argv[1:]

def request(path, host, *, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Host": host}
    if data is not None:
        headers["Content-Type"] = "application/json"
    prepared = Request(
        f"http://caddy{path}",
        data=data,
        headers=headers,
        method="POST" if data is not None else "GET",
    )
    for attempt in range(30):
        try:
            with urlopen(prepared, timeout=5) as response:
                return response.status, json.load(response)
        except URLError:
            if attempt == 29:
                raise
            time.sleep(1)
    raise AssertionError("unreachable")

hub_ready = request("/readyz", hub_host)
push_ready = request("/readyz", push_host)
assert hub_ready == (200, {"status": "ready"}), hub_ready
assert push_ready == (200, {"status": "ready"}), push_ready

# The shared public Hub origin must route this phone-only endpoint to Push.
challenge_status, challenge = request("/v2/attest/challenge", hub_host)
assert challenge_status == 200, challenge_status
raw_challenge = challenge["challenge"]
decoded_challenge = base64.urlsafe_b64decode(
    raw_challenge + "=" * (-len(raw_challenge) % 4)
)
assert len(decoded_challenge) == 32, len(decoded_challenge)

public_key = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode()
enrollment = {
    "enrollment_id": enrollment_id,
    "route_type": "agent",
    "auth_public_key": public_key,
}
created_status, created = request(
    "/v2/enroll/provisional", hub_host, payload=enrollment
)
assert created_status == 201, (created_status, created)
assert created["enrollment_id"] == enrollment_id, created
assert created["status"] == "provisional", created

retry_status, retried = request(
    "/v2/enroll/provisional", hub_host, payload=enrollment
)
assert retry_status == 200, (retry_status, retried)
assert retried["route_id"] == created["route_id"], (created, retried)

print(
    json.dumps(
        {
            "hub_ready": True,
            "push_ready": True,
            "caddy_phone_route": True,
            "hub_postgresql_write_and_retry": True,
            "push_postgresql_write": True,
        },
        sort_keys=True,
    )
)
"""


def verify_topology_and_ordering(config: dict, containers: dict[str, dict]) -> None:
    services = config["services"]
    if set(services) != EXPECTED_SERVICES:
        raise AssertionError(f"incomplete Compose topology: {sorted(services)}")
    if services["caddy"].get("ports"):
        raise AssertionError("CI must not publish Caddy ports on the runner")
    for private_service in (
        "relay-hub",
        "relay-hub-db",
        "push-gateway",
        "push-gateway-db",
    ):
        if services[private_service].get("ports"):
            raise AssertionError(f"CI published private service {private_service}")

    expected_dependencies = {
        ("relay-hub-migrate", "relay-hub-db"): "service_healthy",
        ("relay-hub", "relay-hub-migrate"): "service_completed_successfully",
        ("push-gateway-migrate", "push-gateway-db"): "service_healthy",
        ("push-gateway", "push-gateway-migrate"): "service_completed_successfully",
        ("caddy", "relay-hub"): "service_healthy",
        ("caddy", "push-gateway"): "service_healthy",
    }
    for (dependent, dependency), condition in expected_dependencies.items():
        actual = services[dependent]["depends_on"][dependency]["condition"]
        if actual != condition:
            raise AssertionError(
                f"{dependent} waits for {dependency} via {actual}, expected {condition}"
            )

    for database in ("relay-hub-db", "push-gateway-db"):
        state = containers[database]["State"]
        if state["Status"] != "running" or state["Health"]["Status"] != "healthy":
            raise AssertionError(f"{database} is not healthy: {state}")

    for migration in ("relay-hub-migrate", "push-gateway-migrate"):
        state = containers[migration]["State"]
        if state["Status"] != "exited" or state["ExitCode"] != 0:
            raise AssertionError(f"{migration} did not complete successfully: {state}")

    for application in ("relay-hub", "push-gateway"):
        state = containers[application]["State"]
        if state["Status"] != "running" or state["Health"]["Status"] != "healthy":
            raise AssertionError(f"{application} is not healthy: {state}")

    if containers["caddy"]["State"]["Status"] != "running":
        raise AssertionError("Caddy is not running")

    chains = (
        ("relay-hub-db", "relay-hub-migrate", "relay-hub"),
        ("push-gateway-db", "push-gateway-migrate", "push-gateway"),
    )
    caddy_started = timestamp(containers["caddy"]["State"]["StartedAt"])
    for database, migration, application in chains:
        migration_started = timestamp(containers[migration]["State"]["StartedAt"])
        migration_finished = timestamp(containers[migration]["State"]["FinishedAt"])
        application_started = timestamp(containers[application]["State"]["StartedAt"])
        if not successful_health_before(containers[database], migration_started):
            raise AssertionError(f"{migration} started before {database} was healthy")
        if migration_finished > application_started:
            raise AssertionError(f"{application} started before {migration} finished")
        if not successful_health_before(containers[application], caddy_started):
            raise AssertionError(f"Caddy started before {application} was healthy")


def verify_production_environment(containers: dict[str, dict]) -> None:
    expectations = {
        "relay-hub": ("HRH", "postgresql+psycopg://"),
        "push-gateway": ("HPG", "postgresql+psycopg://"),
    }
    for service, (prefix, database_scheme) in expectations.items():
        values = environment(containers[service])
        if values.get(f"{prefix}_PRODUCTION") != "true":
            raise AssertionError(f"{service} did not start in production mode")
        if values.get(f"{prefix}_AUTO_CREATE_SCHEMA") != "false":
            raise AssertionError(f"{service} was allowed to auto-create its schema")
        if not values.get(f"{prefix}_DATABASE_URL", "").startswith(database_scheme):
            raise AssertionError(f"{service} is not connected through psycopg")


def verify_http_and_postgresql() -> tuple[str, str, str]:
    direct_hub = compose("exec", "-T", "relay-hub", "python", "-c", READY_PROBE, "8080")
    direct_push = compose(
        "exec", "-T", "push-gateway", "python", "-c", READY_PROBE, "8081"
    )
    if '"status": "ready"' not in direct_hub or '"status": "ready"' not in direct_push:
        raise AssertionError("direct /readyz probes did not report ready")

    project = os.environ.get("COMPOSE_PROJECT_NAME", "hrp2-ci")
    suffix = hashlib.sha256(project.encode()).hexdigest()[:12]
    enrollment_id = f"enr_ci_{suffix}"
    smoke = compose(
        "exec",
        "-T",
        "relay-hub",
        "python",
        "-c",
        PROXY_AND_WRITE_SMOKE,
        public_host(os.environ["HRH_PUBLIC_HOST"]),
        public_host(os.environ["HPG_PUBLIC_HOST"]),
        enrollment_id,
    )
    evidence = json.loads(smoke.splitlines()[-1])
    if not all(evidence.values()):
        raise AssertionError(f"HTTP smoke evidence incomplete: {evidence}")

    hub_rows = int(
        psql(
            "relay-hub-db",
            "relay_hub",
            "relay_hub",
            "SELECT count(*) FROM routes "
            f"WHERE enrollment_id = '{enrollment_id}' AND status = 'provisional'",
        )
    )
    if hub_rows != 1:
        raise AssertionError(f"Hub PostgreSQL write count was {hub_rows}, expected 1")

    challenge_rows = int(
        psql(
            "push-gateway-db",
            "push_gateway",
            "push_gateway",
            "SELECT count(*) FROM attest_challenges",
        )
    )
    if challenge_rows < 1:
        raise AssertionError("Push challenge was not persisted in PostgreSQL")

    runtime_schema_version = int(
        compose(
            "exec",
            "-T",
            "push-gateway",
            "python",
            "-c",
            "from push_gateway.storage import PUSH_SCHEMA_VERSION; "
            "print(PUSH_SCHEMA_VERSION)",
        )
    )
    database_schema_version = int(
        psql(
            "push-gateway-db",
            "push_gateway",
            "push_gateway",
            "SELECT max(version) FROM push_schema_migrations",
        )
    )
    if database_schema_version != runtime_schema_version:
        raise AssertionError(
            "Push database schema does not match the running application: "
            f"database={database_schema_version} runtime={runtime_schema_version}"
        )

    hub_postgres = psql(
        "relay-hub-db", "relay_hub", "relay_hub", "SHOW server_version"
    )
    push_postgres = psql(
        "push-gateway-db", "push_gateway", "push_gateway", "SHOW server_version"
    )
    return hub_postgres, push_postgres, str(runtime_schema_version)


def main() -> int:
    config = json.loads(compose("config", "--format", "json"))
    containers = {
        service: container_inspect(service) for service in EXPECTED_SERVICES
    }
    verify_topology_and_ordering(config, containers)
    verify_production_environment(containers)
    hub_postgres, push_postgres, push_schema = verify_http_and_postgresql()
    print(
        "HRP/2 live deployment verified: "
        "PostgreSQL migrations completed before production app startup; "
        "Hub and Push /readyz are healthy; Caddy routing and real writes passed; "
        f"Hub PostgreSQL={hub_postgres}; Push PostgreSQL={push_postgres}; "
        f"Push schema={push_schema}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
