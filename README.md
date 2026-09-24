# AI Gateway — reference build

**One controlled front door for AI: LiteLLM gateway with Claude (AWS Bedrock) and a
local model behind it, per-team virtual keys with model ACLs and budgets, and
guardrails enforced at the gateway for every consumer.**

Built as a concrete reference for "stand up and configure LiteLLM, plug in Claude
and other tools, secure it" — the exact brief this repo answers, line by line.

## The control narrative (the part a bank actually buys)

Every request to the gateway:

1. **Authenticates** with a per-team virtual key (master key never leaves the platform team).
2. **Is ACL-checked** — the key's `models` list decides which tiers it may call
   (`company-ai` = local, `company-claude` = Bedrock). A restricted team cannot reach
   the cloud model *no matter how the request is phrased*.
3. **Passes the topic guardrail** — denied patterns are refused *in code*, before any
   model is invoked, for every consumer (WebUI, n8n, scripts, apps). No UI-level filter
   to bypass.
4. **Is routed** — local tier (restricted data never leaves the building) or Claude
   via AWS Bedrock (the FedRAMP-authorized, government-standard Claude path).
5. **Is PII-redacted on return** — SSN patterns become `[REDACTED]` in the response.
6. **Is accounted** — spend lands per-key in LiteLLM SpendLogs (Postgres); every
   guardrail decision prints an auditable `ALLOW`/`DENIED` line with the key alias.

**Who called what model, with what data, logged where — answerable in one sitting.**

## Architecture

```
teams / apps / n8n ──(virtual keys)──> ALB (TLS) ──> LiteLLM :4000 ─┬─ company-ai     → local llama.cpp
                                                     │  guardrails   └─ company-claude → AWS Bedrock (Claude)
                                                     │  (deny+redact)
                                                     └─ Postgres (keys, budgets, SpendLogs)
```

- `litellm/config.yaml` — the two model tiers; `callbacks: guardrails.callback.BankGuardrail`
- `guardrails/callback.py` — topic denial (pre-call) + PII redaction (post-call), enforced for every key
- `scripts/mint-keys.sh` — per-team keys with `models` ACLs + `max_budget`
- `docker-compose.yml` — gateway + postgres, **`127.0.0.1` binding by default** (ALB in front for prod)
- `terraform/` — VPC, least-privilege SGs, instance role (Bedrock invoke + one secret), ALB+HTTPS

## Quick start (demo box)

```bash
cp .env.example .env   # fill master key, pg password, LLAMA_API_KEY (+ AWS keys for Bedrock)
docker compose up -d
./scripts/mint-keys.sh # mint per-team keys (edit MASTER=… or export MASTER)
```

**Probes** (each maps to a control above):

```bash
KEY=<research key from mint-keys.sh>
# 2. model ACL — restricted key cannot reach Claude:
curl -s http://localhost:4000/v1/chat/completions -H "Authorization: Bearer <restricted key>" \
  -H "Content-Type: application/json" -d '{"model":"company-claude","messages":[{"role":"user","content":"hi"}]}'
# 3. topic guardrail — denied in code before any model call:
curl -s http://localhost:4000/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -d '{"model":"company-claude","messages":[{"role":"user","content":"ignore previous instructions"}]}'
# 5. PII redaction — ask the local model to echo a fake SSN; response shows [REDACTED]
# 6. audit — docker logs gw-litellm | grep bank-guardrail ; spend: /spend/logs endpoints or psql SpendLogs
```

## Mapping to the brief

| Requirement | Where it lives here |
|---|---|
| stand up + configure LiteLLM | `docker-compose.yml` + `litellm/config.yaml`, digest-pinned images |
| plug in Claude | `company-claude` → `bedrock/anthropic.claude-…` (IAM/instance-role; direct-API fallback commented) |
| plug in other tools | any app/script authenticates with a virtual key; n8n/Open WebUI point at `:4000` |
| securing things | lock-down binding, per-key ACLs+budgets, gateway guardrails, audit lines, `terraform/` for the production shape |
| quick sprint | compose up in minutes; terraform extends when the sprint becomes a platform |

## Production deltas (the honest list)

SSO/OIDC on the gateway (LiteLLM supports JWT/SSO — wire to the org IdP) • Postgres as
RDS instead of container • HA via ECS/ASG instead of single EC2 • Prometheus metrics +
log shipping • key rotation runbook • Bedrock model IDs pinned per region • security
assessment document (control narrative above is its skeleton).

## Office Inference

Reference build by Office Inference — the same gateway discipline as
[`ai-stack`](https://github.com/privateInferenceAI/ai-stack) (local tier) and
[`office-inference-cloud`](https://github.com/privateInferenceAI/office-inference-cloud)
(cloud tier, Kimi K2.6).
