"""BankGuardrail — LiteLLM CustomGuardrail enforced at the GATEWAY.

The whole point: policy is enforced where every consumer passes through.
WebUI, n8n, scripts, and internal apps all get IDENTICAL treatment — unlike a
chat-UI-level filter, which anything can bypass by talking to the gateway directly.

Two controls (deterministic, auditable — no model judgment in the enforcement path):
  1. PRE-CALL topic denial  — refused before the request ever reaches a model.
  2. POST-CALL PII redaction — response content is rewritten before it returns.

Access control (which key may call which model, per-key budgets) is NATIVE LiteLLM
(/key/generate with models[] + max_budget) — see scripts/mint-keys.sh. No code needed.

NOTE: hook signatures follow litellm.integrations.custom_guardrail as documented.
Verify against the pinned LiteLLM version when bumping (the integration module has
evolved quickly; see docs.litellm.ai/docs/proxy/guardrails/custom_guardrail).
"""

import re

from fastapi import HTTPException
from litellm.integrations.custom_guardrail import CustomGuardrail

# Same policy surface as the WebUI filter (keep in sync with guardrails/policy.txt):
DENIED_KEYWORDS = (
    "salary of", "how much does", "ssn", "social security number",
    "ignore previous instructions", "ignore all previous", "you are now", "system:",
)
REFUSAL_MESSAGE = "Request denied by gateway policy. Contact your administrator."
PII_PATTERNS = (r"\b\d{3}-\d{2}-\d{4}\b",)   # SSN -> [REDACTED]


class BankGuardrail(CustomGuardrail):
    """Pre-call topic denial + post-call PII redaction, enforced for every key."""

    @staticmethod
    def _last_user_text(data: dict) -> str:
        for m in reversed(data.get("messages", []) or []):
            if m.get("role") == "user":
                return (m.get("content") or "").lower()
        return ""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        """Runs before the model call. Raise to deny; return data to allow."""
        text = self._last_user_text(data)
        for kw in DENIED_KEYWORDS:
            if kw in text:
                # AUDIT LINE: denial events must be greppable for the control narrative.
                print(
                    f"[bank-guardrail] DENIED "
                    f"key_alias={user_api_key_dict.get('key_alias')} "
                    f"team={user_api_key_dict.get('team_id')} keyword={kw!r}"
                )
                raise HTTPException(status_code=400, detail=REFUSAL_MESSAGE)
        print(
            f"[bank-guardrail] ALLOW key_alias={user_api_key_dict.get('key_alias')} "
            f"model={data.get('model')}"
        )
        return data

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        """Runs on the model's response. Redact PII patterns before returning."""
        try:
            for choice in getattr(response, "choices", []) or []:
                content = getattr(choice.message, "content", None)
                if isinstance(content, str):
                    for pat in PII_PATTERNS:
                        content = re.sub(pat, "[REDACTED]", content)
                    choice.message.content = content
        except Exception as e:  # fail open on redaction errors, but log them
            print(f"[bank-guardrail] redaction error (passing through): {e}")
        return response
