# 项目概览：llm-d-kv-cache-manager

## 一、项目定位

`llm-d-kv-cache-manager` 是一个 Go 实现的 KV-Cache 感知路由库，用于分布式 LLM 推理平台。它维护一个近实时的全局视图，追踪 vLLM Pod 集群中 KV-Cache 块的位置信息，实现基于缓存命中率的智能请求路由。

**核心能力**：
- 通过 ZMQ 订阅 vLLM 事件流 (`KVEvents`)，实时更新 KV-Cache 块索引
- 为调度器提供 Pod 评分接口，根据 prompt 计算各 Pod 的缓存命中得分
- 支持多种索引后端（内存 LRU、成本感知内存、Redis 分布式）
- 与 vLLM 的 KV-Block 哈希算法完全兼容（SHA-256 + CBOR）

---

## 二、目录结构与职责

| 目录 | 主要职责 | 关键文件 |
|------|---------|---------|
| **pkg/kvcache/** | KV-Cache 索引核心模块 | `indexer.go`（主协调器）<br>`kvblock_scorer.go`（Pod 评分器） |
| **pkg/kvcache/kvblock/** | KV-Block 索引存储与处理 | `index.go`（索引接口定义）<br>`in_memory.go`（双层 LRU 实现）<br>`cost_aware_memory.go`（Ristretto 实现）<br>`redis.go`（Redis 后端）<br>`token_processor.go`（Token → KV-Block Key 转换器） |
| **pkg/kvcache/kvevents/** | KV-Cache 事件摄取 | `pool.go`（分片工作池，FNV-1a 哈希分片）<br>`zmq_subscriber.go`（ZMQ 订阅器）<br>`events.go`（事件结构定义） |
| **pkg/kvcache/metrics/** | Prometheus 指标采集 | `collector.go`（指标收集器） |
| **pkg/tokenization/** | Tokenizer 池与缓存 | `pool.go`（HuggingFace tokenizer 池）<br>`tokenizer.go`（Tokenizer 封装） |
| **pkg/tokenization/prefixstore/** | Token 前缀缓存 | `lru_store.go`（LRU 缓存）<br>`trie_store.go`（Trie 前缀树） |
| **pkg/preprocessing/chat_completions/** | 对话预处理（CGO 调用 Python） | `cgo_functions.go`（聊天模板处理） |
| **pkg/utils/** | 通用工具 | `slices.go`（切片操作）<br>`logging/levels.go`（日志级别） |
| **examples/** | 示例与参考实现 | `kv_cache_index/`（索引器示例）<br>`kv_cache_aware_scorer/`（调度器集成）<br>`kv_events/`（事件处理示例） |
| **tests/e2e/** | 端到端测试 | E2E 测试用例（使用 miniredis） |
| **deploy/** | Kubernetes 部署配置 | `kustomization.yaml`（Kustomize 配置）<br>`common/`（共享资源） |
| **vllm-setup-helm/** | vLLM Helm Chart | vLLM 部署配置 |
| **benchmarking/** | 性能基准测试 | Tokenization、聊天模板基准测试 |
| **hack/tools/** | 开发工具 | 构建工具脚本 |
| **hooks/** | Git 钩子 | 代码提交前检查 |

---

## 三、构建与运行方式

### 3.1 Makefile 命令（推荐）

```bash
# 安装依赖
make download-tokenizer       # 下载 HuggingFace tokenizer 绑定
make install-python-deps      # 创建 Python venv 并安装依赖（transformers）
make download-zmq             # 安装 ZMQ 库（libzmq3-dev）

# 构建
make build                    # 构建二进制文件到 bin/llm-d-kv-cache-manager

# 运行
make run                      # 构建 + 运行（默认入口：examples/kv_events/online/main.go）

# 测试
make test                     # 运行所有测试（单元测试 + E2E 测试）
make unit-test                # 仅运行单元测试（./pkg/...）
make e2e-test                 # 仅运行 E2E 测试（./tests/...）
make bench                    # 运行基准测试

# 代码检查
make precommit                # 运行所有预提交检查（tidy-go、lint、copr-fix）
make lint                     # 运行 golangci-lint
make tidy-go                  # 整理 go.mod 和 go.sum
make copr-fix                 # 添加版权头

# 容器操作
make image-build              # 构建 Docker 镜像
make image-push               # 推送镜像到 ghcr.io/llm-d/

# 部署
make install-k8s              # 使用 Kustomize 部署到 Kubernetes
make uninstall-k8s            # 从 Kubernetes 删除
```

### 3.2 直接使用 Go 命令

```bash
# 需要先设置环境变量（详见 Makefile 中的 CGO_CFLAGS 和 CGO_LDFLAGS）
export CGO_ENABLED=1
export CGO_CFLAGS="-I/path/to/python/include -Ilib"
export CGO_LDFLAGS="-L/path/to/python/lib -lpython3.12 -Llib -ltokenizers -ldl -lm"

# 运行
go run examples/kv_events/online/main.go

# 测试
go test -v ./pkg/...
```

### 3.3 Docker 容器

```bash
# 构建镜像
docker build -t llm-d-kv-cache-manager:latest .

# 运行容器
docker run -d --name kv-cache-manager llm-d-kv-cache-manager:latest
```

### 3.4 Kubernetes 部署

```bash
# 使用 Kustomize
export NAMESPACE=hc4ai-operator
kustomize build deploy | kubectl apply -f -
```

---

## 四、外部依赖

### 4.1 核心运行时依赖

| 依赖项 | 用途 | 版本要求 | 安装方式 |
|--------|------|----------|----------|
| **Go** | 编译器 | 1.24.1+ | https://golang.org/dl/ |
| **Python** | 聊天模板处理（CGO） | 3.12 | `apt install python3.12-dev` / `brew install python@3.12` |
| **ZMQ** | 事件订阅（ZMQ Subscriber） | libzmq 3+ | `apt install libzmq3-dev` / `brew install zeromq` |
| **HuggingFace Tokenizers** | Tokenization | v1.22.1 | `make download-tokenizer` |

### 4.2 Go 模块依赖（go.mod）

| 模块 | 用途 | 文件引用 |
|------|------|----------|
| `github.com/pebbe/zmq4` | ZMQ 绑定 | `pkg/kvcache/kvevents/zmq_subscriber.go` |
| `github.com/daulet/tokenizers` | HuggingFace tokenizer 绑定 | `pkg/tokenization/tokenizer.go` |
| `github.com/redis/go-redis/v9` | Redis 客户端 | `pkg/kvcache/kvblock/redis.go` |
| `github.com/dgraph-io/ristretto/v2` | 成本感知缓存 | `pkg/kvcache/kvblock/cost_aware_memory.go` |
| `github.com/hashicorp/golang-lru/v2` | LRU 缓存 | `pkg/kvcache/kvblock/in_memory.go` |
| `github.com/vmihailenco/msgpack/v5` | Msgpack 编码 | `pkg/kvcache/kvevents/events.go` |
| `github.com/fxamacker/cbor/v2` | CBOR 编码（KV-Block 哈希） | `pkg/kvcache/kvblock/token_processor.go` |
| `github.com/prometheus/client_golang` | Prometheus 指标 | `pkg/kvcache/metrics/collector.go` |
| `k8s.io/client-go` | Kubernetes 客户端 | 未直接使用（为未来扩展预留） |
| `github.com/alicebob/miniredis/v2` | Redis 模拟（测试用） | `pkg/kvcache/kvblock/redis_test.go` |

### 4.3 Python 依赖（requirements.txt）

- **transformers**：用于 `pkg/preprocessing/chat_completions/` 中的聊天模板处理（通过 CGO 调用）

### 4.4 数据库/中间件（可选）

| 中间件 | 用途 | 是否必需 |
|--------|------|----------|
| **Redis** | 分布式索引后端（用于多副本部署） | 可选（默认使用内存后端） |

### 4.5 构建工具依赖

| 工具 | 用途 | 安装方式 |
|------|------|----------|
| `make` | 构建自动化 | 系统自带 |
| `golangci-lint` | 代码检查 | https://golangci-lint.run/docs/welcome/install/ |
| `docker`/`podman` | 容器构建 | https://docs.docker.com/get-docker/ |
| `kustomize` | Kubernetes 配置管理 | https://kubectl.docs.kubernetes.io/installation/kustomize/ |
| `jq` | JSON 处理 | `apt install jq` / `brew install jq` |

---

## 五、新手阅读顺序

### 阶段一：理解业务场景与架构（30 分钟）

1. **README.md**
   - 了解项目背景、核心价值、数据流图（Read Path / Write Path）

2. **docs/architecture.md**
   - 深入理解架构设计、各模块职责、事件处理流程

3. **docs/configuration.md**
   - 了解配置选项、索引后端选择、性能调优参数

4. **CLAUDE.md**（本文件）
   - 快速查阅开发指南、常用命令、代码规范

### 阶段二：核心代码阅读（2-3 小时）

> **按调用链顺序阅读，优先理解主流程**

#### 5.1 数据写入路径（Event Processing）

| 顺序 | 文件 | 关键函数/结构体 | 目的 |
|------|------|----------------|------|
| 1 | `pkg/kvcache/kvevents/events.go` | `Event`、`EventBatch` | 理解事件格式（BlockStored、BlockRemoved、AllBlocksCleared） |
| 2 | `pkg/kvcache/kvevents/zmq_subscriber.go` | `ZMQSubscriber.Run()` | ZMQ 订阅器如何接收事件 |
| 3 | `pkg/kvcache/kvevents/pool.go` | `Pool.Start()`、`worker()` | 分片工作池（FNV-1a 哈希）、顺序保证 |
| 4 | `pkg/kvcache/kvblock/index.go` | `Index` 接口 | 索引接口定义（StoreKVBlockKeys、RemoveKVBlockKeys、LookupKVBlockKeys） |
| 5 | `pkg/kvcache/kvblock/in_memory.go` | `InMemoryIndex` | 双层 LRU 实现细节 |

#### 5.2 数据读取路径（Scoring）

| 顺序 | 文件 | 关键函数/结构体 | 目的 |
|------|------|----------------|------|
| 1 | `pkg/kvcache/indexer.go` | `Indexer.Score()` | 主入口：理解打分流程 |
| 2 | `pkg/tokenization/prefixstore/lru_store.go` | `LRUPrefixStore.Get()` | Token 前缀缓存如何减少 tokenization 开销 |
| 3 | `pkg/tokenization/tokenizer.go` | `Tokenizer.Encode()` | HuggingFace tokenizer 封装 |
| 4 | `pkg/kvcache/kvblock/token_processor.go` | `TokenProcessor.GenerateKVBlockKeys()` | **核心**：Token → KV-Block Key 转换（SHA-256 + CBOR） |
| 5 | `pkg/kvcache/kvblock_scorer.go` | `KVBlockScorer.ScorePods()` | 最长连续前缀匹配打分算法 |

#### 5.3 关键数据结构

| 文件 | 结构体 | 核心字段 | 用途 |
|------|--------|----------|------|
| `pkg/kvcache/indexer.go` | `Indexer` | `index Index`<br>`scorer KVBlockScorer`<br>`prefixStore PrefixStore` | 协调器 |
| `pkg/kvcache/kvblock/index.go` | `KVBlockKey` | `Hash uint64`<br>`Tier CacheTier` | KV-Block 唯一标识 |
| `pkg/kvcache/kvevents/events.go` | `EventBatch` | `PodID string`<br>`Model string`<br>`Events []Event` | 事件批次 |
| `pkg/kvcache/kvblock/token_processor.go` | `TokenProcessor` | `blockSize int`<br>`hashSeed uint64` | Token 分块与哈希配置 |

### 阶段三：运行示例代码（1 小时）

1. **examples/kv_events/offline/**
   - 运行离线示例：使用模拟 ZMQ 发布器发送事件
   - 文件：`examples/kv_events/offline/main.go`

2. **examples/kv_cache_index/**
   - 运行完整索引器示例
   - 文件：`examples/kv_cache_index/main.go`

3. **examples/kv_cache_aware_scorer/**
   - 理解调度器集成方式
   - 文件：`examples/kv_cache_aware_scorer/main.go`

### 阶段四：测试与调试（1-2 小时）

1. **单元测试**
   - 先看简单测试：`pkg/utils/slices_test.go`
   - 核心逻辑测试：`pkg/kvcache/kvblock/token_processor_test.go`
   - 索引后端测试：`pkg/kvcache/kvblock/in_memory_test.go`

2. **E2E 测试**
   - 端到端流程验证：`tests/e2e/` 目录

3. **本地调试**
   ```bash
   # 运行测试（带详细输出）
   make unit-test

   # 运行示例（观察日志）
   make run
   ```

### 阶段五：深入技术细节（按需）

1. **KV-Block 哈希算法对齐**
   - 阅读 `pkg/kvcache/kvblock/token_processor.go`
   - 关注 `computeKVBlockHash()` 函数
   - 理解为何使用 CBOR 编码 + SHA-256 的低 64 位

2. **CGO 集成细节**
   - 阅读 `pkg/preprocessing/chat_completions/cgo_functions.go`
   - 理解如何通过 CGO 调用 Python transformers 库

3. **性能优化技巧**
   - 阅读 `pkg/kvcache/kvevents/pool.go` 中的分片策略
   - 研究 `pkg/kvcache/kvblock/cost_aware_memory.go` 的成本感知淘汰

---

## 六、关键技术点速查

| 技术点 | 文件位置 | 核心逻辑 |
|--------|---------|----------|
| **KV-Block 哈希算法** | `pkg/kvcache/kvblock/token_processor.go:198` | `SHA-256(CBOR([parentHash, tokenChunk, extraKeys]))`<br>取低 64 位 |
| **事件分片保证** | `pkg/kvcache/kvevents/pool.go:87` | FNV-1a 哈希 Pod ID，路由到固定 Worker |
| **Token 前缀缓存** | `pkg/tokenization/prefixstore/lru_store.go:45` | LRU 缓存 `string → []uint32` 映射 |
| **双层 LRU 索引** | `pkg/kvcache/kvblock/in_memory.go:67` | Pod-level LRU → KVBlockKey-level LRU |
| **最长连续匹配** | `pkg/kvcache/kvblock_scorer.go:89` | 计算 Pod 的 KV-Block 连续命中长度 |

---

## 七、常见问题排查

| 问题 | 排查方向 | 相关文件 |
|------|---------|----------|
| **哈希不匹配** | 1. 检查 `PYTHONHASHSEED` 是否与 vLLM 一致<br>2. 确认 `blockSize` 配置（默认 16） | `token_processor.go` |
| **事件顺序错乱** | 查看 Pool Worker 日志，确认同一 Pod 的事件是否由同一 Worker 处理 | `pool.go` |
| **Tokenization 慢** | 1. 检查 PrefixStore 命中率<br>2. 增大 tokenizer pool size | `tokenizer.go`、`lru_store.go` |
| **Redis 连接失败** | 检查 Redis 配置、网络连通性 | `redis.go` |
| **CGO 链接错误** | 确认 Python 3.12 dev headers 已安装<br>检查 `CGO_CFLAGS` 和 `CGO_LDFLAGS` | `Makefile:89-91` |

---

## 八、开发规范提醒

1. **代码提交前**：执行 `make precommit`（包含 tidy、lint、版权头检查）
2. **新增文件**：需包含 Apache 2.0 版权头（`make copr-fix` 自动添加）
3. **测试覆盖**：新功能必须包含单元测试
4. **文档更新**：修改配置/接口时同步更新 `docs/` 目录
5. **提交信息**：遵循 Conventional Commits 规范（feat/fix/docs/chore）

---

## 附录：快速命令参考

```bash
# 快速开始（首次运行）
make download-tokenizer && make install-python-deps && make download-zmq
make build
make run

# 日常开发
make lint              # 代码检查
make unit-test         # 快速测试
make precommit         # 提交前检查

# 性能分析
make bench             # 运行基准测试

# 清理
make clean             # 删除 build/ 目录
```
