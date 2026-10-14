# Research: Cloud STT Free-Tier Providers (for kanso-dictate remote engine)

**Date:** 2026-10-14
**Context:** kanso-dictate remote STT = generic OpenAI-compatible `POST {baseURL}/v1/audio/transcriptions` multipart client (`Sources/KansoCore/Engines/OpenAICompatibleSTTEngine.swift`: fields `model`, `response_format=verbose_json`, `language`, `prompt`, `file=audio.wav`; default Groq `whisper-large-v3-turbo`). Already documented: Groq, OpenAI, Cloudflare, Ollama, vLLM/LocalAI.

## Question

Which OTHER cloud STT providers offer a free tier / trial / credits, what does it cost after, what protocol do they speak, and how hard is integration (drop-in vs new engine class)?

## Method

Primary sources only: official pricing pages, official docs, official announcements/repos. Searched then extracted each official page. Secondary write-ups used only where the official page extract failed, and marked as such.

## Findings table (free tier + paid + protocol + effort)

| Provider | Free tier / trial (primary source) | Paid STT list price (primary source) | Protocol | Streaming | ID+EN | Integration effort |
|---|---|---|---|---|---|---|
| Deepgram | $200 credit, no card, no expiry ([Pricing](https://deepgram.com/pricing)) | Nova-3 pre-rec ~$0.0043/min, streaming ~$0.0048 promo / $0.0077 regular (secondary-verified vs official page, [report](https://brasstranscripts.com/blog/deepgram-pricing-per-minute-2025-real-time-vs-batch)) | Proprietary REST + WS | Yes (WS) | Yes (30+ langs) | New engine class |
| AssemblyAI | $50 credits, no card, no expiry; LLM Gateway excluded ([Billing docs](https://www.assemblyai.com/docs/billing-and-pricing)) | Universal-2 $0.15/hr, Universal-3.5 Pro $0.21/hr ([Pricing](https://www.assemblyai.com/pricing)) | Proprietary `POST /v1/transcript` + realtime WS/SDK ([API ref](https://www.assemblyai.com/docs/api-reference)) | Yes | Yes (99 / 18 langs) | New engine class |
| Speechmatics | $100 credit grant, no card ([Pricing](https://www.speechmatics.com/pricing), [Plans docs](https://docs.speechmatics.com/administration/plans)) | Melia 1 $0.12/hr, Standard $0.23/hr, Enhanced $0.38/hr ([Pricing](https://www.speechmatics.com/pricing)) | Proprietary REST + WS | Yes | Yes (55+ langs) | New engine class |
| Rev.ai | 5 hrs Reverb ASR free credits ([Pricing](https://www.rev.ai/pricing)) | Reverb $0.20/hr EN, $0.30/hr 57+ langs, Whisper-Large $0.005/min ([Pricing](https://www.rev.ai/pricing)) | Proprietary async + streaming REST/WS | Yes | Yes (57+ langs) | New engine class |
| ElevenLabs Scribe | Free plan 10k credits/mo (~12 min STT) ([STT page](https://elevenlabs.io/speech-to-text)) | Scribe v2 $0.22/hr, Realtime $0.39/hr ([API pricing](https://elevenlabs.io/pricing/api)) | Proprietary REST `xi-api-key` + WS `/v1/speech-to-text/realtime` ([Docs](https://elevenlabs.io/docs/api-reference/speech-to-text)) | Yes | Yes (99+ langs) | New engine class |
| Mistral Voxtral | No free tier on official pricing (pay-per-min only) ([Pricing](https://docs.mistral.ai/inference/pricing)) | Voxtral Mini Transcribe 2 $0.003/min ([Pricing](https://docs.mistral.ai/inference/pricing)); v1 from $0.001/min ([Announcement](https://mistral.ai/news/voxtral)) | OpenAI-compatible `/v1/audio/transcriptions` ([Announcement](https://mistral.ai/news/voxtral-transcribe-2)); realtime model + open weights Apache-2.0 | Yes (Realtime $0.006/min) | 13 langs batch, multilingual | Drop-in (verify field mapping) |
| Fireworks AI | $1 free credits ([Pricing](https://fireworks.ai/pricing)) | Whisper v3-large-turbo $0.0009/min, v3-large $0.0015/min ([Launch blog](https://fireworks.ai/blog/audio-transcription-launch)) | OpenAI-compatible `/v1/audio/transcriptions` | No (batch) | Yes (Whisper langs) | Drop-in |
| Together AI | No advertised free tier; prepaid, $5 min top-up (secondary; official page lists rates only) ([Pricing](https://www.together.ai/pricing)) | Whisper Large v3 $0.0015/min, streaming $0.0035/min, Parakeet $0.0015/min ([Pricing](https://www.together.ai/pricing), [Model page](https://www.together.ai/models/openai-whisper-large-v3)) | OpenAI-compatible Whisper endpoint | Yes | Yes | Drop-in |
| OpenRouter | No signup grant; 25+ `:free` LLM variants throttled, STT passthrough + ~5.5% credit fee ([Pricing](https://openrouter.ai/pricing)) | Provider passthrough; cost in `usage.cost` per request ([STT docs](https://openrouter.ai/docs/guides/overview/multimodal/stt)) | OpenAI-compatible `/api/v1/audio/transcriptions` AND chat `input_audio` ([STT docs](https://openrouter.ai/docs/guides/overview/multimodal/stt)) | Via providers | Via providers | Drop-in (+1 hop latency) |
| Cloudflare Workers AI | 10k Neurons/day free ongoing (secondary; neuron rates official) ([PricePerToken](https://pricepertoken.com/endpoints/cloudflare/free)) | Whisper $0.0005/min (41.14 neurons/min), whisper-large-v3-turbo same ([Pricing docs](https://developers.cloudflare.com/workers-ai/platform/pricing), [Model page](https://developers.cloudflare.com/workers-ai/models/whisper)) | Proprietary Workers AI REST (account ID + token), NOT OpenAI-compatible | No (REST) | Yes (Whisper langs) | New engine class (small) |
| HuggingFace Inference Providers | ~$0.10/mo free credits; PRO $2/mo (secondary citing official) | Provider pass-through, no markup (secondary) | OpenAI-compatible `router.huggingface.co/v1` | Via providers | Via model | Drop-in (credit too small to matter) |
| Google Gemini Dev API | Free tier (rate-limited RPD, no card; paid models excluded) ([Billing](https://ai.google.dev/gemini-api/docs/billing), [Pricing](https://ai.google.dev/gemini-api/docs/pricing)) | Gemini 3.5 Transcribe ~$0.005/min blended; Transcribe Live ~$0.009/min ([Pricing](https://ai.google.dev/gemini-api/docs/pricing)) | Proprietary Gemini REST/WS (`generateContent`, files), NOT OpenAI-compatible | Yes (Live) | Yes (auto-detect, 70+ langs translate) | New engine class |
| Google Cloud STT | 60 min/mo free ([Pricing](https://cloud.google.com/speech-to-text/pricing)); $300/90-day GCP credit (GCP-wide) | V1 std $0.024/min (no logging), $0.016/min (with logging); medical $0.078/min ([Pricing](https://cloud.google.com/speech-to-text/pricing)) | Proprietary REST/gRPC + streaming | Yes | Yes (125+ langs) | New engine class |
| Azure AI Speech | F0 5 audio hrs/mo free ([Pricing](https://azure.microsoft.com/en-us/pricing/details/cognitive-services/speech-services/)) | S0 metered per-second (see pricing page; commitment tiers separate) ([Pricing](https://azure.microsoft.com/en-us/pricing/details/cognitive-services/speech-services/)) | Proprietary SDK/REST/WS | Yes | Yes (140+ locales) | New engine class |
| AWS Transcribe | 60 min/mo x 12 mo ([Pricing](https://aws.amazon.com/transcribe/pricing/)) | Tier-1 $0.024/min, billed per-second ([Pricing](https://aws.amazon.com/transcribe/pricing/)) | Proprietary SDK/REST + streaming WS | Yes | Yes (100+ langs) | New engine class (heavy SDK, card required) |
| Picovoice (on-device alt) | Free trial tier (key from console; offline inference) ([Docs](https://picovoice.ai/docs)) | Contact sales / subscription (no public per-min rate) ([Pricing](https://picovoice.ai/pricing/)) | Native SDK (Cheetah streaming / Leopard batch), NOT HTTP | Yes (Cheetah) | EN-focused + custom vocab | New engine class (native lib, AccessKey validation needs net once) |
| Cerebras | None — NO STT offered; voice-agent guide pairs Cerebras LLM + OpenAI Whisper for STT ([Docs](https://inference-docs.cerebras.ai/integrations/livekit)) | N/A | N/A | N/A | N/A | Exclude |

Notes:
- OpenAI itself (already documented): `whisper-1` $0.006/min; `gpt-4o-mini-transcribe` ~$0.003/min; $5 dev credit reported (secondary: [CostGoat](https://costgoat.com/pricing/openai-transcription), [Cartesia](https://www.cartesia.ai/learn/openai-whisper-api-pricing)). OpenAI-compatible by definition — drop-in.
- Gladia (discovered extra, vendor-reported only, official pricing extract failed): 10 free hrs/mo recurring; Pro ~$0.61/hr async, $0.75/hr realtime ([vendor blog](https://www.gladia.io/blog/deepgram-pricing)). Proprietary REST/WS. New engine. Attractive recurring free tier if verified on official page before budgeting.
- Deepgram STT per-min rates above are secondary-verified-against-official; the $200/no-expiry/no-card claim is direct from the official page extract.

## Per-provider detail

### Deepgram — biggest one-time credit, streaming-first
- Models: Nova-3 (current), Whisper-hosted also available via Cloudflare proxy. Free: $200 credit, no card, no expiry ([Pricing](https://deepgram.com/pricing)). Paid: ~$0.0043/min batch, ~$0.0048–0.0077/min streaming ([report](https://brasstranscripts.com/blog/deepgram-pricing-per-minute-2025-real-time-vs-batch)). Auth: API key. ID+EN: yes. Effort: new engine (REST `POST /v1/listen` + WS `wss://api.deepgram.com/v1/listen`); response JSON differs from OpenAI verbose_json. PTT fit: excellent (low-latency streaming, per-second billing).

### AssemblyAI — most free hours, cheapest base rate
- Models: Universal-2 ($0.15/hr, 99 langs), Universal-3.5 Pro ($0.21/hr, 18 langs) ([Pricing](https://www.assemblyai.com/pricing)). Free $50, no expiry ([Billing docs](https://www.assemblyai.com/docs/billing-and-pricing)). Auth: API key. Effort: new engine (`POST /v1/transcript` polling or realtime WS). PTT fit: good; batch polling adds latency vs WS.

### Speechmatics — $100 grant, strong multilingual
- Models: Melia 1 $0.12/hr (56 langs, code-switch), Standard $0.23/hr, Enhanced $0.38/hr ([Pricing](https://www.speechmatics.com/pricing)). Free: $100 grant, no card ([Plans docs](https://docs.speechmatics.com/administration/plans)). Effort: new engine (REST + WS realtime). PTT fit: good.

### Rev.ai — small but simple free slice
- Free: 5 hrs Reverb ASR ([Pricing](https://www.rev.ai/pricing)). Paid: $0.20/hr EN / $0.30/hr foreign / Whisper $0.005/min. Effort: new engine. PTT fit: OK; English-only cheapest tier limits ID use (foreign tier $0.30/hr still cheap).

### ElevenLabs Scribe — tiny free, best accuracy-per-dollar paid
- Models: Scribe v2, v2 Realtime, v2 Medical. Free: 10k credits/mo ≈ 12 min ([STT page](https://elevenlabs.io/speech-to-text)). Paid: $0.22/hr batch, $0.39/hr realtime ([API pricing](https://elevenlabs.io/pricing/api)). Auth: `xi-api-key`. Effort: new engine (REST + WS). PTT fit: very good (150ms realtime claim); free tier too small for dev loop.

### Mistral Voxtral — best DROP-IN candidate
- Model: Voxtral Mini Transcribe 2, $0.003/min ([Pricing](https://docs.mistral.ai/inference/pricing)). Endpoint `/v1/audio/transcriptions` ([Announcement](https://mistral.ai/news/voxtral-transcribe-2)). Open weights Apache-2.0; realtime variant $0.006/min. No free tier found. Auth: Bearer key. Effort: drop-in — only needs baseURL+model swap, then verify `verbose_json` shape. PTT fit: excellent (cheap, fast, OpenAI-compatible).

### Fireworks AI — cheapest drop-in, $1 taste
- Free: $1 credits ([Pricing](https://fireworks.ai/pricing)). Paid: Whisper turbo $0.0009/min ([Launch blog](https://fireworks.ai/blog/audio-transcription-launch)). Effort: drop-in. PTT fit: good for batch; no streaming STT.

### Together AI — cheap drop-in, no free lunch
- Paid: Whisper Large v3 $0.0015/min, streaming $0.0035/min ([Pricing](https://www.together.ai/pricing)). No free tier advertised. Effort: drop-in. PTT fit: good.

### OpenRouter — one key, many STTs, fee + hop
- Free: only `:free` LLM variants; STT billed passthrough + 5.5% ([Pricing](https://openrouter.ai/pricing)). Protocol: `/api/v1/audio/transcriptions` + chat `input_audio` ([STT docs](https://openrouter.ai/docs/guides/overview/multimodal/stt)). Effort: drop-in (baseURL swap). PTT fit: mediocre (extra hop, free caps 50–1000 req/day per secondary).

### Cloudflare Workers AI — cheapest paid + daily free
- Paid: Whisper $0.0005/min ([Pricing docs](https://developers.cloudflare.com/workers-ai/platform/pricing)). Free: 10k Neurons/day ≈ 200+ whisper-minutes/day (secondary calc from official neuron rate). Protocol: proprietary Workers REST ([Model page](https://developers.cloudflare.com/workers-ai/models/whisper)). Effort: small new engine (single REST call, JSON `{text}`). PTT fit: excellent (edge latency, near-zero cost).

### HuggingFace — negligible credit, skip
- ~$0.10/mo free; OpenAI-compatible router. Drop-in but credit covers minutes. Skip except for model variety.

### Google Gemini Developer API — generous token free tier, new protocol
- Free tier with per-model RPD limits ([Billing](https://ai.google.dev/gemini-api/docs/billing)); dedicated Transcribe models ~$0.005/min blended ([Pricing](https://ai.google.dev/gemini-api/docs/pricing)). Effort: new engine (upload audio → `generateContent`; realtime via WS). PTT fit: good; free tier best for prototyping a Gemini path, but latency higher than WS STT specialists.

### Google Cloud STT / Azure / AWS — hyperscaler trail, heavyweight SDKs
- Google: 60 min/mo free ([Pricing](https://cloud.google.com/speech-to-text/pricing)). Azure F0: 5 hrs/mo free ([Pricing](https://azure.microsoft.com/en-us/pricing/details/cognitive-services/speech-services/)). AWS: 60 min/mo x 12 mo ([Pricing](https://aws.amazon.com/transcribe/pricing/)). All need new engine classes + card/identity hurdles. Azure F0 recurring 5 hrs is the best hyperscaler free deal. PTT fit: fine (all stream), but integration cost highest.

### Picovoice — offline alternative, not cloud
- Cheetah (streaming) / Leopard (batch) run 100% on-device ([Docs](https://picovoice.ai/docs)); free trial via console key. Native SDK per platform, AccessKey needs one-time online validation. Effort: new engine + SPM/pod dependency. PTT fit: best latency/privacy story; accuracy below cloud SOTA; consider only if offline requirement emerges.

## Recommendation (ranked: free generosity + OpenAI-compat + PTT latency fit)

1. **Mistral Voxtral** — implement first: drop-in to existing engine, $0.003/min cheapest mainstream, realtime option. No free tier, but pennies to evaluate.
2. **Fireworks AI** — second drop-in: $1 credit + $0.0009/min turbo; near-zero code.
3. **Deepgram** — first NEW engine: $200 free + best streaming latency for PTT; Nova-3 value after credit.
4. **Cloudflare Workers AI** — cheapest long-run ($0.0005/min) + daily free; small REST engine, edge latency.
5. **AssemblyAI** — $50 free = ~185 hrs batch; cheapest base ($0.15/hr); batch-polling latency weaker for PTT.
6. **Speechmatics** — $100 grant; Melia $0.12/hr multilingual is PTT-relevant.
7. **Azure F0** — only recurring hyperscaler free (5 hrs/mo); do last (SDK weight).
8. Skip: Cerebras (no STT), HuggingFace (trivial credit), OpenRouter (fee+hop unless multi-provider routing needed), AWS/GCP (trial expires, card friction), Picovoice (only if offline needed), Gladia (verify official pricing first).

## Sources

- https://deepgram.com/pricing
- https://www.assemblyai.com/pricing
- https://www.assemblyai.com/docs/billing-and-pricing
- https://www.assemblyai.com/docs/api-reference
- https://www.speechmatics.com/pricing
- https://docs.speechmatics.com/administration/plans
- https://www.rev.ai/pricing
- https://elevenlabs.io/speech-to-text
- https://elevenlabs.io/pricing/api
- https://elevenlabs.io/docs/api-reference/speech-to-text
- https://mistral.ai/news/voxtral
- https://mistral.ai/news/voxtral-transcribe-2
- https://docs.mistral.ai/inference/pricing
- https://docs.mistral.ai/capabilities/audio
- https://fireworks.ai/pricing
- https://fireworks.ai/blog/audio-transcription-launch
- https://www.together.ai/pricing
- https://www.together.ai/models/openai-whisper-large-v3
- https://openrouter.ai/pricing
- https://openrouter.ai/docs/guides/overview/multimodal/stt
- https://developers.cloudflare.com/workers-ai/platform/pricing
- https://developers.cloudflare.com/workers-ai/models/whisper
- https://huggingface.co/pricing
- https://ai.google.dev/gemini-api/docs/pricing
- https://ai.google.dev/gemini-api/docs/billing
- https://cloud.google.com/speech-to-text/pricing
- https://azure.microsoft.com/en-us/pricing/details/cognitive-services/speech-services/
- https://aws.amazon.com/transcribe/pricing/
- https://console.groq.com/docs/rate-limits
- https://picovoice.ai/docs
- https://picovoice.ai/pricing/
- https://inference-docs.cerebras.ai/integrations/livekit
- https://www.gladia.io/pricing
- https://openai.com/api/pricing/
