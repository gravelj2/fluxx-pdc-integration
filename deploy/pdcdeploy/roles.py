"""List the Fluxx `Role` records available in an instance.

Listing only, for visibility -- not cross-referenced against anything else
yet. See docs/roadmap.md "Setting roles on workflow objects" for the planned
future use (picking the right role when configuring a MachineEvent).
"""

from __future__ import annotations

from dataclasses import dataclass

from .fluxx_client import FluxxClient

ROLE_LIST_COLS = ["id", "name", "roleable_type"]


@dataclass(frozen=True)
class RoleRef:
    id: int
    name: str
    roleable_type: str


def list_roles(client: FluxxClient) -> list[RoleRef]:
    records = client.list_all("role", ROLE_LIST_COLS)
    return [RoleRef(id=r["id"], name=r["name"], roleable_type=r["roleable_type"]) for r in records]
