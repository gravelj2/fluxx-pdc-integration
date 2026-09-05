"""Minimal Fluxx REST v2 client.

Stdlib only (urllib), per the package-level design constraint.

Two REST quirks this client works around (confirmed by hand against TRN on
2026-09-04, see docs/stencil-import-export-api.md and the fluxx-rest-api-facts
memory):

- The `filter` param is silently ignored by this instance for the model types
  probed here (`stencil`, `model_method`, `machine_event`) -- it neither
  errors nor restricts results. Bare triplets (`["field","eq",value]`) instead
  return a hard `{"error": {"code": 100, ...}}`. There is no known working
  filter syntax, so this client does not expose one: callers must fetch a full
  page and filter client-side. `per_page` maxes at 500, which comfortably
  covers every model type this tool touches so far (274 stencils, 405
  model_methods, 998 machine_events as of the 2026-09-04 probe).
- Unknown/inapplicable `cols` entries are not rejected -- they come back as
  `null` per record instead of raising. A `None` value in a filtered column
  more likely means "wrong column name" than "empty field"; use `all_core=1`
  on a single record to discover real field names when unsure.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

MAX_PER_PAGE = 500


class FluxxApiError(RuntimeError):
    """Raised when Fluxx returns an HTTP error or an {"error": ...} envelope."""


@dataclass
class FluxxClient:
    base_url: str
    token: str

    def _request(self, method: str, path: str, params: dict | None = None) -> dict:
        qs = urllib.parse.urlencode(params or {})
        url = f"{self.base_url}/api/rest/v2/{path}"
        if qs:
            url = f"{url}?{qs}"
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {self.token}"},
            method=method,
        )
        try:
            with urllib.request.urlopen(req) as resp:
                body = resp.read()
        except urllib.error.HTTPError as exc:
            raise FluxxApiError(f"{method} {path} -> HTTP {exc.code}: {exc.read()[:500]!r}") from exc

        data = json.loads(body)
        if isinstance(data, dict) and "error" in data:
            raise FluxxApiError(f"{method} {path} -> {data['error']}")
        return data

    def list_all(self, model_type: str, cols: list[str]) -> list[dict]:
        """Fetch every record of `model_type`, one page at a time.

        No server-side filter (see module docstring) -- callers filter the
        returned list themselves.
        """
        records: list[dict] = []
        page = 1
        while True:
            data = self._request(
                "GET",
                model_type,
                {"cols": json.dumps(cols), "per_page": MAX_PER_PAGE, "page": page},
            )
            batch = data["records"].get(model_type, [])
            records.extend(batch)
            if page >= data.get("total_pages", 1):
                break
            page += 1
        return records

    def fetch(self, model_type: str, model_id: int, cols: list[str] | None = None) -> dict:
        params = {"cols": json.dumps(cols)} if cols else {"all_core": 1}
        data = self._request("GET", f"{model_type}/{model_id}", params)
        return data[model_type]
