"""Hermes Relay Protocol v2.

The v2 package is intentionally separate from the local plaintext v1 relay.
Importing it has no side effects and ``python -m hermes_relay`` continues to
select v1 unless the operator explicitly asks for ``--protocol v2``.
"""

PROTOCOL_VERSION = 2
