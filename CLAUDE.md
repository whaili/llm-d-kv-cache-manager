# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

The `llm-d-kv-cache-manager` is a Go-based library for KV-Cache aware routing in distributed LLM inference platforms. It maintains a near-real-time global view of KV-Cache block locality across vLLM pods, enabling intelligent request routing based on cache hit rates.

## Development Commands

### Building and Running
```bash
make build                    # Build the application binary
make run                      # Build and run the application
make download-tokenizer       # Download HuggingFace tokenizer bindings (required for build)
make install-python-deps      # Set up Python venv and install dependencies
make download-zmq             # Install ZMQ dependencies
```

### Testing
```bash
make test                     # Run all tests (unit + e2e)
make unit-test                # Run unit tests only (./pkg/...)
make e2e-test                 # Run e2e tests only (./tests/...)
make bench                    # Run benchmarks
```

### Code Quality
```bash
make precommit                # Run all precommit checks (tidy-go, lint, copr-fix)
make lint                     # Run golangci-lint
make tidy-go                  # Tidy go.mod and go.sum
make copr-fix                 # Add copyright headers
```

### Container Operations
```bash
make image-build              # Build Docker image
make image-push               # Push Docker image to registry
```

### Deployment
```bash
make install-k8s              # Deploy to Kubernetes using kustomize
make uninstall-k8s            # Remove from Kubernetes
```

## Architecture Overview

The KV-Cache Indexer consists of several coordinated modules:

### Core Components

1. **`kvcache.Indexer`** (pkg/kvcache/indexer.go)
   - Main orchestrator that handles scoring requests
   - Coordinates tokenization, key generation, index lookup, and scoring

2. **`kvevents.Pool`** (pkg/kvcache/kvevents/pool.go)
   - Ingests KV-cache events from vLLM pods via ZMQ
   - Sharded worker pool for processing events (uses FNV-1a hashing for pod-based sharding)
   - Guarantees in-order processing of events from the same pod

3. **`kvblock.Index`** (pkg/kvcache/kvblock/index.go)
   - Core data store mapping KV-block hashes to pod locations
   - Multiple backend implementations:
     - **InMemory**: Fast two-level LRU cache (default)
     - **CostAwareMemory**: Memory-efficient with cost-aware eviction (ristretto-based)
     - **Redis**: Distributed backend for multi-replica deployments

4. **`tokenization.PrefixStore`** (pkg/tokenization/prefixstore/)
   - LRU cache for tokenized prompt prefixes
   - Reduces redundant tokenization work

5. **`kvblock.TokenProcessor`** (pkg/kvcache/kvblock/token_processor.go)
   - Converts token sequences into KV-block keys
   - Implements chunking and hashing compatible with vLLM
   - Uses SHA-256 with CBOR encoding for deterministic hashing

6. **`kvblock.Scorer`** (pkg/kvcache/kvblock_scorer.go)
   - Scores pods based on consecutive KV-cache hits
   - Implements longest consecutive prefix matching

### Data Flow

**Read Path (Scoring):**
1. Router requests pod scores for a prompt
2. Indexer checks PrefixStore for cached tokens (falls back to synchronous tokenization if needed)
3. Tokens converted to KV-block keys via TokenProcessor
4. Index queried to find which pods have those blocks
5. Scorer calculates pod scores based on consecutive hits
6. Scores returned to router

**Write Path (Event Processing):**
1. vLLM pods emit KV-cache events (BlockStored, BlockRemoved, AllBlocksCleared) via ZMQ
2. Events parsed to extract pod ID and model from topic: `kv@pod-id@model`
3. Pool routes events to specific worker via consistent hashing
4. Worker decodes msgpack payload and updates Index

### Key Implementation Details

- **KV-Block Hashing**: Must match vLLM's content-addressing logic
  - Token chunking: Fixed-size chunks (default 16 tokens)
  - Hash algorithm: Lower 64 bits of SHA-256 hash of CBOR-encoded `[parentHash, tokenChunk, extraKeys]`
  - Hash seed must align with `PYTHONHASHSEED` in vLLM pods

- **CGO Dependencies**: Project uses CGO for HuggingFace tokenizers and Python chat template processing
  - Requires Python 3.12 development headers
  - Build flags configured in Makefile: `CGO_CFLAGS` and `CGO_LDFLAGS`

- **Event Format**: Uses msgpack encoding for vLLM events
  - Events are batched in `EventBatch` structs
  - Tagged union format for polymorphic event types

## Project Structure

```
pkg/
├── kvcache/              # Main KV-cache indexer implementation
│   ├── indexer.go        # Orchestrator
│   ├── kvblock/          # Block indexing and processing
│   ├── kvevents/         # Event ingestion (ZMQ subscribers, pool)
│   └── metrics/          # Prometheus metrics collector
├── tokenization/         # Tokenizer pool and caching
│   └── prefixstore/      # Token prefix caching (LRU, Trie)
├── preprocessing/        # Chat completion preprocessing (Python CGO)
└── utils/                # Shared utilities

examples/
├── kv_cache_index/       # Reference implementation of indexer
├── kv_cache_aware_scorer/# Integration example for schedulers
└── kv_events/            # Online/offline event handling examples

tests/
└── e2e/                  # End-to-end tests

deploy/                   # Kubernetes deployment configs (kustomize)
vllm-setup-helm/         # Helm chart for vLLM setup
```

## Configuration

The system is highly configurable through the `kvcache.Config` struct which combines:
- `PrefixStoreConfig`: Token prefix cache settings
- `TokenProcessorConfig`: Chunking and hashing parameters
- `KVBlockIndexConfig`: Backend selection and metrics
- `KVBlockScorerConfig`: Scoring algorithm parameters
- `TokenizersPoolConfig`: Tokenizer pool size and behavior

## Testing Notes

- Unit tests require tokenizer bindings, Python deps, and ZMQ to be installed first
- E2e tests use miniredis for mocking Redis backend
- Tests are located in `*_test.go` files alongside implementation
- Benchmarks available for chat templates and tokenization

## Dependencies

**Runtime:**
- Go 1.24.1+
- Python 3.12 (for chat template processing via CGO)
- ZMQ (libzmq3-dev on Linux, zeromq on macOS)
- HuggingFace tokenizer bindings (auto-downloaded via make)

**External Libraries:**
- github.com/pebbe/zmq4 - ZMQ bindings
- github.com/daulet/tokenizers - HuggingFace tokenizer bindings
- github.com/redis/go-redis/v9 - Redis client
- github.com/dgraph-io/ristretto/v2 - Cost-aware cache
- github.com/hashicorp/golang-lru/v2 - LRU cache
- k8s.io/client-go - Kubernetes client
- github.com/vmihailenco/msgpack/v5 - Msgpack encoding

## Common Development Patterns

1. **Adding new index backends**: Implement the `kvblock.Index` interface in pkg/kvcache/kvblock/
2. **Event handling**: Events are processed in worker goroutines; ensure thread-safety
3. **Metrics**: Use the instrumented index wrapper when EnableMetrics is true
4. **Testing with Redis**: Use miniredis for unit tests; real Redis for e2e

## Reply Guidelines
- Always reference **file path + function name** when explaining code.
- Use **Mermaid diagrams** for flows, call chains, and module dependencies.
- If context is missing, ask explicitly which files to `/add`.
- Never hallucinate non-existing functions or files.
- Always reply in **Chinese**

## Excluded Paths
- vendor/
- build/
- dist/
- .git/
- third_party/

## Glossary


## Run Instructions