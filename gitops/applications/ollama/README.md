# Ollama

CPU-only Ollama deployment on OpenShift. Models are pulled at pod startup by an init container and persisted on a 50 GiB LVMS PVC. Add models by editing `OLLAMA_PULL_MODELS` in `configmap-models.yaml` and restarting the deployment.

**Endpoint (in-cluster):** `http://ollama.app-ollama.svc.cluster.local:11434`  
**OpenAI-compatible API:** append `/v1` to either URL.

---

## Deployed Models

### Home Assistant Voice Assistant

Speed is the primary constraint. The LLM turn in HA's voice pipeline (Whisper → LLM → Piper) must complete in ~2–3 s or the voice UX degrades. That means small, fast models ≤4B.

| Model | Size | Reason |
|---|---|---|
| `gemma3:4b` | ~3.3 GB | Best quality at this size; strong instruction following |
| `qwen2.5:3b` | ~2.0 GB | Fastest option; good at short, structured responses |

### Pi Agent

Interactive but not voice — a 5–10 s response is acceptable. Priority is reasoning quality, code understanding, and complex instruction following.

| Model | Size | Reason |
|---|---|---|
| `qwen2.5:14b` | ~9 GB | Excellent at coding, structured output, and agentic tasks |
| `deepseek-r1:14b` | ~9 GB | Chain-of-thought reasoning model; thinks step by step before answering |

### Comparison Baseline

Middle-ground models to compare quality/speed tradeoffs between the two use-case extremes.

| Model | Size | Reason |
|---|---|---|
| `gemma3:9b` | ~5.8 GB | Strong all-rounder between voice-fast and agent-quality |
| `deepseek-r1:7b` | ~4.7 GB | Cheaper reasoning model to benchmark against the 14B |

**Total on PVC:** ~34 GB of the 50 GB available.

---

## Model Nomenclature

### Parameters — the "B" number

The number of weights in the network. More = smarter, but more memory and slower.

| Size | Typical capability |
|---|---|
| 1–4B | Simple Q&A, fast voice responses |
| 7–9B | Good general purpose, coding, instruction following |
| 13–14B | Multi-step reasoning, noticeably smarter |
| 32B+ | Near GPT-3.5/4 territory; needs significant RAM |

### Quantization — the "Q" number

Reduces bits-per-weight to shrink memory footprint at a small quality cost.

| Tag | Bits | Size vs original | Quality loss |
|---|---|---|---|
| `fp16` | 16 | 50% | negligible |
| `Q8_0` | 8 | 25% | barely noticeable |
| `Q5_K_M` | 5 | 16% | small — good CPU balance |
| `Q4_K_M` | 4 | 12% | moderate — **Ollama default** |
| `Q3_K_M` | 3 | 9% | noticeable |
| `Q2_K` | 2 | 6% | significant — last resort |

`_K` = k-quant (smarter, applies higher precision to sensitive layers). `_M` / `_L` = medium / large variant of that quant level.

**More parameters at lower precision beats fewer parameters at higher precision** — up to a point. Quantization reduces weight precision but preserves the knowledge and reasoning capacity encoded across all parameters. A 14B Q4 model will outperform a 7B Q8 model at the same memory footprint in almost every case. The quality cliff hits at Q3 and below, where rounding errors visibly degrade coherence and reasoning. **Q4_K_M is the practical floor; prefer a larger model at Q4 over a smaller model at Q8 for the same RAM budget.**

### Memory estimate

```
RAM needed ≈ (Parameters × bits ÷ 8) + ~15% overhead (KV-cache, runtime)
```

| Model | Q4_K_M size | ~RAM needed |
|---|---|---|
| 3B | 1.9 GB | ~2.5 GB |
| 4B | 2.6 GB | ~3.5 GB |
| 7–8B | 4.5 GB | ~5.5 GB |
| 9B | 5.8 GB | ~7 GB |
| 14B | 8.5 GB | ~10 GB |
| 32B | 20 GB | ~23 GB |
| 70B | 43 GB | ~50 GB |

### GPU vs CPU

All inference here runs on CPU (Intel Xeon E5-1650 V3, no GPU). A GPU is not required but dramatically increases speed due to memory bandwidth:

| Hardware | Bandwidth | ~Tokens/s (8B Q4) |
|---|---|---|
| This cluster (DDR4) | ~60 GB/s | 3–8 tok/s |
| RTX 4090 (24 GB) | 1008 GB/s | 80–120 tok/s |

The entire model must fit in VRAM for full GPU speed. Overflow to system RAM drops performance to CPU-level. On this cluster, RAM (256 GiB) is the superpower — large models that wouldn't fit on a single consumer GPU run fine, just slowly.

---

## Selecting More Models

1. Browse [ollama.com/library](https://ollama.com/library) for available models and tags.
2. Estimate RAM from the table above — the deployment limit is currently **20 GiB**, so models up to ~14B (Q4) load comfortably. Bump `resources.limits.memory` in `deployment.yaml` for larger ones.
3. Check PVC headroom: `oc exec -n app-ollama deployment/ollama -- df -h /root/.ollama`
4. Add the model tag (space-separated) to `OLLAMA_PULL_MODELS` in `configmap-models.yaml`.
5. Commit, push, and restart: `oc rollout restart deployment/ollama -n app-ollama`
6. Watch progress: `oc logs -f -n app-ollama deployment/ollama -c model-puller`
