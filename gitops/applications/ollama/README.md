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


### GPU vs. CPU

Here is that breakdown formatted in clean, scannable Markdown using clear text variables instead of code blocks for the mathematical notation:

### The Two LLM Processing Phases

* **Reading the Input (The Prefill Phase) is Compute-Bound ($O(N^2)$ complexity):** Because the model processes your entire prompt simultaneously, it triggers massive matrix-matrix multiplications. Every input token looks at every other input token, demanding heavy arithmetic processing power where GPUs and Tensor Cores shine.
* **Generating the Output (The Decode Phase) is Memory-Bound ($O(N)$ complexity):** Because the model predicts text sequentially—one single token at a time—it triggers simple matrix-vector math. The arithmetic is trivial, but the processor is forced to load the entire multi-gigabyte model from RAM just to output a single word, making your RAM's transfer speed the ultimate speed limit.

### Prompt Caching (Prefill Phase)

As long as the beginning of your prompt stays the same, Ollama keeps the processed input math cached in your RAM pool. When you ask a follow-up question, the CPU skips the compute-heavy prefill phase entirely for the old text and instantly jumps straight to generating your output tokens.

### Estimating Output Token Speed (Decode Phase)

LLM inference is memory-bandwidth bound — the bottleneck is how fast model weights can be streamed through the processor per token generated. The formula is:

```
tokens/sec ≈ memory_bandwidth_GB/s ÷ model_size_GB × efficiency_factor
```

The **efficiency factor** (~0.6–0.7) accounts for CPU compute overhead, memory latency, and OS scheduling. Theoretical bandwidth is never fully utilized in practice.

**This cluster:** Intel Xeon E5-1650 V3 with DDR4-2133 quad-channel (4 channels × 2133 MT/s × 8 bytes = **~68 GB/s theoretical, ~60–65 GB/s real-world**).

Estimated token speed for deployed models (Q4_K_M, efficiency 0.65):

| Model | Size | Calculation | ~Tokens/s |
|---|---|---|---|
| `qwen2.5:3b` | 2.0 GB | 65 ÷ 2.0 × 0.65 | ~21 tok/s |
| `gemma3:4b` | 2.6 GB | 65 ÷ 2.6 × 0.65 | ~16 tok/s |
| `deepseek-r1:7b` | 4.5 GB | 65 ÷ 4.5 × 0.65 | ~9 tok/s |
| `gemma3:9b` | 5.8 GB | 65 ÷ 5.8 × 0.65 | ~7 tok/s |
| `qwen2.5:14b` | 9.0 GB | 65 ÷ 9.0 × 0.65 | ~5 tok/s |
| `deepseek-r1:14b` | 9.0 GB | 65 ÷ 9.0 × 0.65 | ~5 tok/s |

These are estimates — actual speed depends on context length, prompt complexity, and system load. Use them for relative comparison and go/no-go decisions, not as guarantees.
