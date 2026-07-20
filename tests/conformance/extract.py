"""Static wire-surface extractors for the conformance suite (A2/N1).

The suite asserts key-for-key agreement between THREE independently-written
surfaces; this module extracts the ACTUAL surface from each source so the tests
compare live code, not hand-maintained copies:

1. iOS (Swift, regex-based): the ``RelayClient`` upstream payload builders, the
   ``RelayUpstreamMethod`` / ``RelayFrameKind`` / ``ChatItemType`` enums, the
   ``RelayFrame`` / ``ChatItem`` / body-projection decoders, and the shared
   ``ApprovalRequestPayload`` / ``ClarifyRequestPayload`` gate decoders.
2. Relay (Python, ast-based): the ``handle_upstream`` per-method param readers
   in ``downstream.py`` and the gateway RPC param dicts in ``gateway_client.py``.
3. Gateway (Python, ast-based): the ``params`` reads of each ``@method(...)``
   handler in ``tui_gateway/server.py`` (the in-repo ground truth for the
   relay -> gateway edge).

Pure static analysis: nothing here imports app code, touches the network, or
needs a venv beyond pytest.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
IOS = REPO_ROOT / "apps" / "ios" / "HermesMobile"
RELAY = REPO_ROOT / "relay" / "hermes_relay"
GATEWAY = REPO_ROOT / "tui_gateway" / "server.py"

_RELAY_CLIENT = IOS / "Networking" / "Relay" / "RelayClient.swift"
_RELAY_PROTOCOL = IOS / "Models" / "RelayProtocol.swift"
_CHAT_ITEM = IOS / "Models" / "ChatItem.swift"
_PROTOCOL_TYPES = IOS / "Models" / "ProtocolTypes.swift"
_JSONRPC = IOS / "Models" / "JSONRPC.swift"

# Keys of the JSON-RPC envelope builder inside RelayClient.notify — subtracted
# from per-method sends (they are envelope, asserted separately).
_RPC_ENVELOPE_KEYS = frozenset({"jsonrpc", "method", "params", "id"})


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _brace_block(source: str, open_idx: int) -> str:
    """Return the text of the brace block whose `{` is at/after ``open_idx``."""
    start = source.index("{", open_idx)
    depth = 0
    for i in range(start, len(source)):
        ch = source[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start : i + 1]
    raise ValueError("unbalanced braces")


def _enum_block(source: str, name: str) -> str:
    m = re.search(rf"\benum\s+{re.escape(name)}\b[^\{{]*", source)
    if not m:
        raise AssertionError(f"enum {name} not found")
    return _brace_block(source, m.start())


# ---------------------------------------------------------------------------
# Swift: upstream surface
# ---------------------------------------------------------------------------


def _swift_upstream_raw_values() -> dict[str, str]:
    """``RelayUpstreamMethod`` case name -> WIRE raw value, declaration order.

    Cases without an explicit raw value use their case name as the wire name
    (every pre-§6a method); ``push.register``/``push.unregister`` (§6a) carry
    explicit dotted raw values distinct from their case names.
    """
    block = _enum_block(_read(_RELAY_PROTOCOL), "RelayUpstreamMethod")
    out: dict[str, str] = {}
    for m in re.finditer(r'^\s*case\s+(\w+)(?:\s*=\s*"([^"]+)")?', block, flags=re.M):
        out[m.group(1)] = m.group(2) or m.group(1)
    return out


def swift_upstream_methods() -> list[str]:
    """The ``RelayUpstreamMethod`` raw values (every upstream RPC the phone can send)."""
    return list(_swift_upstream_raw_values().values())


def _func_blocks(source: str) -> list[tuple[str, str]]:
    """(func-name, full brace-balanced body) pairs — overloads appear more than
    once, so this is a list, not a map."""
    out: list[tuple[str, str]] = []
    for m in re.finditer(r"\bfunc\s+(\w+)\s*\(", source):
        try:
            out.append((m.group(1), _brace_block(source, m.start())))
        except ValueError:
            continue
    return out


_KEY_IN_DICT = re.compile(r'"([a-z_]+)"\s*:\s*\.(?:string|number|bool|null|object|array)\b')
_KEY_ASSIGN = re.compile(r'params\["([a-z_]+)"\]\s*=')
_METHOD_CALL = re.compile(r"(?:request|notify)\(\s*\.(\w+)")


def swift_upstream_sends() -> dict[str, dict[str, list[str]]]:
    """Per upstream method: the param keys the iOS builder ALWAYS sends
    (``required`` — dict-literal entries) and CONDITIONALLY sends (``optional``
    — ``params["k"] =`` assignments, which in this client are all if-guarded).
    """
    source = _read(_RELAY_CLIENT)
    wire_names = _swift_upstream_raw_values()
    sends: dict[str, dict[str, set[str]]] = {}
    for _func_name, body in _func_blocks(source):
        call = _METHOD_CALL.search(body)
        if not call:
            continue  # a convenience wrapper that never builds a wire payload
        # ``request(.pushRegister, ...)`` captures the CASE name; key by the
        # WIRE name so the map lines up with the relay's UpstreamMethod.ALL and
        # the fixture (identical for every pre-§6a method).
        method = wire_names.get(call.group(1), call.group(1))
        required = {
            k
            for k in _KEY_IN_DICT.findall(body)
            if k not in _RPC_ENVELOPE_KEYS
        }
        optional = set(_KEY_ASSIGN.findall(body)) - _RPC_ENVELOPE_KEYS
        slot = sends.setdefault(method, {"required": set(), "optional": set()})
        slot["required"] |= required - optional
        slot["optional"] |= optional - required
    return {
        method: {
            "required": sorted(v["required"]),
            "optional": sorted(v["optional"] - v["required"]),
        }
        for method, v in sends.items()
    }


def _coding_keys(enum_block: str) -> list[str]:
    """Every wire key declared in a ``CodingKeys`` block (``case a, b, c`` lines;
    the ``case x = "wire"`` form yields the raw wire string)."""
    keys: list[str] = []
    for line in enum_block.splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[len("case ") :].split(","):
            part = part.strip()
            m = re.match(r'(\w+)\s*=\s*"([^"]+)"', part)
            if m:
                keys.append(m.group(2))
            elif re.match(r"^\w+$", part):
                keys.append(part)
    return keys


def swift_rpc_request_envelope() -> list[str]:
    """``JSONRPCRequest`` CodingKeys — the outbound request envelope keys."""
    source = _read(_JSONRPC)
    block = _enum_block(
        _brace_block(source, source.index("struct JSONRPCRequest")),
        "CodingKeys",
    )
    return _coding_keys(block)


# ---------------------------------------------------------------------------
# Swift: downstream surface
# ---------------------------------------------------------------------------


def swift_frame_kinds() -> dict[str, str]:
    """Map wire string -> Swift case for ``RelayFrameKind`` (init(wire:))."""
    block = _enum_block(_read(_RELAY_PROTOCOL), "RelayFrameKind")
    return dict(re.findall(r'case\s+"([^"]+)"\s*:\s*self\s*=\s*\.(\w+)', block))


def swift_frame_envelope() -> list[str]:
    """``RelayFrame`` CodingKeys — the downstream envelope keys iOS decodes."""
    proto = _read(_RELAY_PROTOCOL)
    frame_struct = proto.index("struct RelayFrame")
    block = _enum_block(proto[frame_struct:], "CodingKeys")
    return _coding_keys(block)


def swift_item_types() -> list[str]:
    """``ChatItemType`` raw values (the item types iOS decodes natively)."""
    block = _enum_block(_read(_CHAT_ITEM), "ChatItemType")
    # Cases only (the enum body also has an init(wire:) — no `case` lines in it).
    return re.findall(r"^\s*case\s+(\w+)", block, flags=re.M)


def swift_chat_item_json_keys() -> list[str]:
    """Keys ``ChatItem(json:)`` reads from an item body (item.started/completed/snapshot)."""
    source = _read(_CHAT_ITEM)
    init = source.index("init?(json: JSONValue)")
    block = _brace_block(source, init)
    return sorted(set(re.findall(r'json\["([a-z_]+)"\]', block)))


def swift_body_projection_keys() -> dict[str, list[str]]:
    """Keys the typed body projections read (item.delta / snapshot / usage)."""
    proto = _read(_RELAY_PROTOCOL)
    out: dict[str, list[str]] = {}
    for struct, key in (("RelayItemDelta", "item.delta"), ("RelaySnapshot", "snapshot")):
        idx = proto.index(f"struct {struct}")
        block = _brace_block(proto, idx)
        out[key] = sorted(set(re.findall(r'body\["([a-z_]+)"\]', block)))
    # RelayFrame.usage: body["usage"] ?? body
    out["turn.completed"] = ["usage"]
    return out


def swift_gate_decoder_keys() -> dict[str, list[str]]:
    """Keys the shared approval/clarify payload decoders read (both transports)."""
    source = _read(_PROTOCOL_TYPES)
    out: dict[str, list[str]] = {}
    for struct, key in (
        ("ApprovalRequestPayload", "approval.request"),
        ("ClarifyRequestPayload", "clarify.request"),
    ):
        idx = source.index(f"struct {struct}")
        block = _brace_block(source, idx)
        out[key] = sorted(set(re.findall(r'payload\["([a-z_]+)"\]', block)))
    return out


# ---------------------------------------------------------------------------
# Python (ast): relay readers
# ---------------------------------------------------------------------------


def _parse(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _method_guard(test: ast.expr) -> set[str] | None:
    """The UpstreamMethod set an ``if`` test guards (None = not a method guard)."""
    def attr_name(node: ast.expr) -> str | None:
        if (
            isinstance(node, ast.Attribute)
            and isinstance(node.value, ast.Name)
            and node.value.id == "UpstreamMethod"
        ):
            return node.attr
        return None

    if isinstance(test, ast.Compare) and isinstance(test.left, ast.Name) and test.left.id == "method":
        if len(test.ops) == 1 and isinstance(test.ops[0], ast.Eq):
            name = attr_name(test.comparators[0])
            return {name} if name else None
        if len(test.ops) == 1 and isinstance(test.ops[0], ast.In) and isinstance(
            test.comparators[0], ast.Tuple
        ):
            names = {n for n in (attr_name(e) for e in test.comparators[0].elts) if n}
            return names or None
    return None


def _collect_param_reads(
    body: list[ast.stmt],
    guard_stack: list[set[str] | None],
    out: dict[str, dict[str, set[str]]],
) -> None:
    """Recurse a handle_upstream body, attributing p["k"]/p.get("k") reads to the
    intersection of enclosing ``method ==`` guards."""
    for stmt in body:
        if isinstance(stmt, ast.If):
            guard = _method_guard(stmt.test)
            if guard is not None:
                _collect_param_reads(stmt.body, guard_stack + [guard], out)
                _collect_param_reads(stmt.orelse, guard_stack, out)
                continue
        for node in ast.walk(stmt):
            key = None
            bucket = None
            # p["k"]  -> required read
            if (
                isinstance(node, ast.Subscript)
                and isinstance(node.value, ast.Name)
                and node.value.id == "p"
                and isinstance(node.slice, ast.Constant)
                and isinstance(node.slice.value, str)
            ):
                key, bucket = node.slice.value, "required"
            # p.get("k", default) -> optional read
            elif (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "get"
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "p"
                and node.args
                and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str)
            ):
                key, bucket = node.args[0].value, "optional"
            if key is None:
                continue
            effective: set[str] | None = None
            for g in guard_stack:
                if g is None:
                    continue
                effective = g if effective is None else (effective & g)
            methods = effective if effective is not None else _ALL_METHODS
            for m in methods:
                slot = out.setdefault(m, {"required": set(), "optional": set()})
                slot[bucket].add(key)


_ALL_METHODS: set[str] = set()  # filled by relay_upstream_reads()


def relay_upstream_reads() -> dict[str, dict[str, list[str]]]:
    """Per upstream method: the ``params`` keys ``handle_upstream`` reads, split
    into required (``p["k"]`` — a missing key raises) and optional (``p.get``)."""
    from hermes_relay.types import UpstreamMethod  # noqa: PLC0415 (path set by conftest)

    global _ALL_METHODS
    _ALL_METHODS = set(UpstreamMethod.ALL)

    def resolve(attr: str) -> str:
        """UpstreamMethod attribute (``SUBMIT``) -> wire value (``submit``)."""
        return str(getattr(UpstreamMethod, attr))

    tree = _parse(RELAY / "downstream.py")
    func = next(
        n
        for n in ast.walk(tree)
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == "handle_upstream"
    )
    raw: dict[str, dict[str, set[str]]] = {}
    _collect_param_reads(func.body, [], raw)
    # Guard attribution lands on attribute names (SUBMIT); map to wire values.
    out: dict[str, dict[str, set[str]]] = {}
    for attr, v in raw.items():
        slot = out.setdefault(resolve(attr), {"required": set(), "optional": set()})
        slot["required"] |= v["required"]
        slot["optional"] |= v["optional"]
    return {
        m: {
            "required": sorted(v["required"]),
            "optional": sorted(v["optional"] - v["required"]),
        }
        for m, v in out.items()
    }


def relay_gateway_rpc_params() -> dict[str, dict[str, list[str]]]:
    """Per gateway RPC: the param keys ``gateway_client.py`` puts on the wire,
    split into always-sent (dict literal in the call) and conditional
    (``params["k"] =`` under an if)."""
    tree = _parse(RELAY / "gateway_client.py")
    out: dict[str, dict[str, set[str]]] = {}
    for func in ast.walk(tree):
        if not isinstance(func, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for node in ast.walk(func):
            rpc = None
            params_dict = None
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr in ("call", "_call_result")
                and node.args
                and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str)
            ):
                rpc = node.args[0].value
                for arg in node.args[1:]:
                    if isinstance(arg, ast.Dict):
                        params_dict = arg
            if rpc is None:
                continue
            slot = out.setdefault(rpc, {"required": set(), "optional": set()})
            if params_dict is None:
                # `_call_result(rpc, params)` with a NAME arg: resolve the dict
                # the function assigned to that name (its literal keys are all
                # sent unconditionally).
                name = next(
                    (
                        a.id
                        for a in node.args[1:]
                        if isinstance(a, ast.Name) and a.id == "params"
                    ),
                    None,
                )
                if name is not None:
                    for sub in ast.walk(func):
                        value = None
                        if (
                            isinstance(sub, ast.Assign)
                            and len(sub.targets) == 1
                            and isinstance(sub.targets[0], ast.Name)
                            and sub.targets[0].id == name
                        ):
                            value = sub.value
                        elif (
                            isinstance(sub, ast.AnnAssign)
                            and isinstance(sub.target, ast.Name)
                            and sub.target.id == name
                            and sub.value is not None
                        ):
                            value = sub.value
                        if isinstance(value, ast.Dict):
                            params_dict = value
                            break
            if params_dict is not None:
                for k in params_dict.keys:
                    if isinstance(k, ast.Constant) and isinstance(k.value, str):
                        slot["required"].add(k.value)
            # params["k"] = ... assignments in the same function are conditional.
            for sub in ast.walk(func):
                if (
                    isinstance(sub, ast.Assign)
                    and len(sub.targets) == 1
                    and isinstance(sub.targets[0], ast.Subscript)
                    and isinstance(sub.targets[0].value, ast.Name)
                    and sub.targets[0].value.id == "params"
                    and isinstance(sub.targets[0].slice, ast.Constant)
                    and isinstance(sub.targets[0].slice.value, str)
                ):
                    slot["optional"].add(sub.targets[0].slice.value)
    return {
        rpc: {
            "required": sorted(v["required"]),
            "optional": sorted(v["optional"] - v["required"]),
        }
        for rpc, v in out.items()
    }


# ---------------------------------------------------------------------------
# Python (ast): gateway readers (in-repo ground truth)
# ---------------------------------------------------------------------------


def gateway_handler_reads() -> dict[str, dict[str, list[str]]]:
    """Per ``@method("rpc")`` handler in tui_gateway/server.py: the ``params``
    keys it reads — required (``params["k"]``) and optional (``params.get``).
    For handlers delegating to ``_respond(rid, params, key)`` the answer key
    (the third literal arg) is folded in as an optional read, mirroring the
    generic responder's ``params.get(key, "")``."""
    tree = _parse(GATEWAY)
    out: dict[str, dict[str, set[str]]] = {}
    for func in ast.walk(tree):
        if not isinstance(func, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        rpc = None
        for deco in func.decorator_list:
            if (
                isinstance(deco, ast.Call)
                and isinstance(deco.func, ast.Name)
                and deco.func.id == "method"
                and deco.args
                and isinstance(deco.args[0], ast.Constant)
            ):
                rpc = deco.args[0].value
        if rpc is None:
            continue
        slot = out.setdefault(rpc, {"required": set(), "optional": set()})
        for node in ast.walk(func):
            if (
                isinstance(node, ast.Subscript)
                and isinstance(node.value, ast.Name)
                and node.value.id == "params"
                and isinstance(node.slice, ast.Constant)
                and isinstance(node.slice.value, str)
            ):
                slot["required"].add(node.slice.value)
            elif (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "get"
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "params"
                and node.args
                and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str)
            ):
                slot["optional"].add(node.args[0].value)
            elif (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "_respond"
                and len(node.args) >= 3
                and isinstance(node.args[2], ast.Constant)
                and isinstance(node.args[2].value, str)
            ):
                # _respond(rid, params, "answer"|"text"|...): it reads request_id
                # plus the named answer key.
                slot["optional"].add(node.args[2].value)
                slot["optional"].add("request_id")
    return {
        rpc: {
            "required": sorted(v["required"]),
            "optional": sorted(v["optional"] - v["required"]),
        }
        for rpc, v in out.items()
    }
