# Ollama Performance — Optimization TODO

## Current State (2026-06-05)

| Item | Value |
|---|---|
| Model | `gemma4:e4b` (8B params, Q4_K_M, ~10 GB in RAM) |
| Inference | CPU-only — no GPU |
| CPU | Intel Xeon E5-1650 V3 — 6 cores / 12 threads, single socket |
| CPU limit (container) | 8 vCPU |
| CPU scaling | **92% of max** — not running at full clock |
| Memory limit | 64 GiB |
| `OLLAMA_NUM_THREADS` | 6 |
| Context length | 4096 tokens (Ollama default) |
| Theoretical bandwidth | ~65 GB/s (DDR4-2133 quad-channel) |
| Theoretical max tok/s | ~4 tok/s for 10 GB model (`65 ÷ 10 × 0.65`) |

**The hard ceiling:** CPU inference speed is memory-bandwidth bound.
No config change will beat physics — 65 GB/s is the wall.
Tuning buys maybe 20–40% on top of where we are, not 10×.

---

## Establish a Baseline First

Before changing anything, measure actual throughput so improvements are comparable:

```bash
# Tokens/s — run a few times and average
curl -s http://localhost:11434/api/generate \
  -d '{"model":"gemma4:e4b","prompt":"Explain Kubernetes in detail.","stream":false}' \
  | jq '{eval_rate: .eval_count, duration_s: (.eval_duration/1e9), tok_s: (.eval_count / (.eval_duration/1e9))}'

# Is memory bandwidth the actual bottleneck? Run stream benchmark on the node:
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
  -- chroot /host sh -c "dnf install -yq stream && stream" 2>/dev/null
```

---

## Optimization Candidates

Ordered by estimated impact. Try one at a time and re-benchmark.

### 1. CPU frequency governor — likely quick win

CPU is running at 92% clock. Setting the governor to `performance` forces
max frequency at all times, eliminating dynamic throttling during inference.

Add a MachineConfig to `gitops/infra/machine-config/`:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-cpu-performance-governor
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.4.0
    systemd:
      units:
      - name: cpu-performance-governor.service
        enabled: true
        contents: |
          [Unit]
          Description=Set CPU governor to performance
          After=multi-user.target
          [Service]
          Type=oneshot
          ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
          [Install]
          WantedBy=multi-user.target
```

### 2. OLLAMA_NUM_THREADS — test 8 and 12

Currently 6 (physical cores). The container limit allows 8 vCPUs.
Hyperthreading (12 threads) rarely helps memory-bandwidth-bound workloads
but worth a test. Edit `deployment.yaml`:

```yaml
- name: OLLAMA_NUM_THREADS
  value: "8"   # try 8 first, then 12
```

### 3. OLLAMA_FLASH_ATTENTION — reduces KV cache memory pressure

Enables flash attention, which recomputes attention scores on-the-fly
instead of storing them. Less memory read/write pressure for long contexts.

```yaml
- name: OLLAMA_FLASH_ATTENTION
  value: "1"
```

### 4. Quantization — trade quality for speed

Dropping from Q4_K_M to Q3_K_M reduces model size by ~25%, directly
translating to ~25% more tokens/sec. Quality degrades noticeably but
may still be acceptable for HA voice where short answers dominate.

Pull and compare:
```bash
# In configmap-models.yaml, temporarily add:
# gemma4:e4b-q3_K_M  (if available on ollama.com/library)
```

### 5. Check memory channel utilization

All four DDR4 channels should be populated (8 × 32 GiB = 2 DIMMs/channel).
Confirm the measured bandwidth matches the theoretical ~65 GB/s:

```bash
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
  -- chroot /host sh -c "cat /proc/cpuinfo | grep 'model name' | head -1"
# Then run stream (see baseline section above) and compare Triad result to ~65 GB/s
```

### 6. Alternative inference engines

Ollama is convenient but not the most optimized CPU runtime. Alternatives:

| Engine | CPU optimization | Notes |
|---|---|---|
| `llama.cpp` (direct) | AVX2/AVX-512 tuning, more flags | More control, less convenience |
| `vLLM` CPU mode | Better batching | Designed for throughput, not latency |
| `llama-cpp-python` server | Same as llama.cpp | Easier to containerize |

Worth evaluating if Ollama tuning plateaus — same GGUF models work across all three.

---

## What Will NOT Help

- **More RAM / bigger memory limit** — both models already fit; adding RAM does not increase bandwidth
- **Higher CPU limit beyond 8** — memory bandwidth saturates before CPU compute does
- **Bigger model** — more parameters = more data to stream = slower, not smarter-and-fast
- **SSD speed** — model loads from PVC once into RAM; disk speed only affects cold start

---

## Realistic Expectations

| Model | Theoretical max | Realistic after tuning |
|---|---|---|
| `gemma4:e4b` (8B, Q4) | ~4 tok/s | ~3–6 tok/s |
| `qwen3-coder:30b-a3b` (MoE, 3B active) | ~28 tok/s | ~15–25 tok/s |

For **HA voice**, 3–6 tok/s on gemma4 means a 20-word answer takes ~10 s.
That is likely too slow for a natural voice feel. `qwen3-coder` is a better
voice candidate purely on speed — despite being a coding model.

For **pi agent**, 3–6 tok/s is slow but usable for non-time-critical tasks.
