# 系统架构文档

## 一、系统整体架构综述

### 1.1 项目定位

**llm-d-kv-cache-manager** 是一个高性能的 KV-Cache 感知路由库，为分布式 LLM 推理平台提供智能调度能力。通过维护跨 vLLM Pod 集群的 KV-Cache 块位置索引，实现基于缓存命中率的最优 Pod 选择。

**核心价值**：
- 🚀 **降低 TTFT**（Time To First Token）：优先选择已有缓存的 Pod
- 📈 **提升吞吐量**：减少重复计算，最大化 KV-Cache 复用
- 🎯 **智能路由**：基于最长连续前缀匹配的 Pod 评分算法
- 🔄 **近实时更新**：通过 ZMQ 事件流保持索引同步

---

### 1.2 设计原则

| 原则 | 实现 | 示例 |
|------|------|------|
| **关注点分离** | 模块化设计，清晰的接口边界 | `Indexer` 协调多个独立模块（Tokenization、Index、Scorer） |
| **可插拔架构** | 基于接口的实现，支持多种后端 | `kvblock.Index` 接口 + 3 种实现（InMemory、Redis、CostAware） |
| **高性能优先** | 多层缓存、并发优化、Pipeline | 4 层 LRU 缓存、Worker Pool、Redis Pipeline |
| **兼容性保证** | 与 vLLM 的 KV-Block 哈希算法完全对齐 | CBOR + SHA-256 + PYTHONHASHSEED 对齐 |
| **容错设计** | 毒丸消息处理、优雅降级 | Unmarshal 失败 → 丢弃消息 + 日志 |

---

### 1.3 核心功能模块

```mermaid
graph TB
    subgraph "Client Layer"
        A[Inference Scheduler]
    end

    subgraph "API Gateway"
        B[HTTP Server<br>:8080]
    end

    subgraph "Application Layer"
        C[kvcache.Indexer<br>主协调器]
        D[preprocessing.ChatTemplatingProcessor<br>CGO → Python]
    end

    subgraph "Service Layer - Read Path"
        E1[tokenization.Pool<br>Worker Pool × 5]
        E2[kvblock.TokenProcessor<br>Token → Keys 转换]
        E3[KVBlockScorer<br>最长前缀打分]
    end

    subgraph "Service Layer - Write Path"
        F1[kvevents.ZMQSubscriber<br>ZMQ 订阅器]
        F2[kvevents.Pool<br>Worker Pool × 4]
    end

    subgraph "Data Layer"
        G1[prefixstore.LRUTokenStore<br>Token 前缀缓存]
        G2[CachedHFTokenizer<br>Tokenizer 模型缓存]
        G3[kvblock.Index<br>索引抽象层]
    end

    subgraph "Storage Backends"
        H1[InMemoryIndex<br>双层 LRU]
        H2[RedisIndex<br>分布式后端]
        H3[CostAwareMemoryIndex<br>Ristretto]
    end

    subgraph "External Systems"
        I1[vLLM Fleet<br>ZMQ Publisher]
        I2[Redis Server]
        I3[HuggingFace Hub]
        I4[Python 3.12<br>transformers]
    end

    A -->|HTTP POST| B
    B --> C
    B --> D

    C --> E1
    C --> E2
    C --> E3
    D --> I4

    E1 --> G1
    E1 --> G2
    E2 --> G3
    E3 --> G3

    I1 -->|ZMQ Pub| F1
    F1 --> F2
    F2 --> G3

    G3 -.->|Backend Choice| H1
    G3 -.->|Backend Choice| H2
    G3 -.->|Backend Choice| H3

    H2 --> I2
    G2 --> I3

    style A fill:#e1f5ff
    style C fill:#fff9c4
    style G3 fill:#c8e6c9
    style I1 fill:#ffccbc
    style I4 fill:#ffccbc
```

**模块职责总结**：

| 层级 | 模块数量 | 职责 | 关键特性 |
|------|---------|------|----------|
| **Client** | 1 | 外部调度器/路由器 | 请求 Pod 评分 |
| **API Gateway** | 1 | HTTP 服务（2 个端点） | `/score_completions`, `/score_chat_completions` |
| **Application** | 2 | 业务逻辑协调 | 协调多个子模块、CGO 调用 |
| **Service** | 5 | 核心算法与工作池 | 异步处理、哈希转换、打分 |
| **Data** | 3 | 缓存与抽象 | 多层 LRU、接口抽象 |
| **Storage** | 3 | 索引存储实现 | 内存/分布式/成本感知 |
| **External** | 4 | 外部依赖 | vLLM、Redis、HuggingFace、Python |

---

## 二、顶层目录结构表

| 目录 | 作用 | 关键文件 | 文件数量 |
|------|------|----------|----------|
| **pkg/kvcache/** | KV-Cache 索引核心模块 | `indexer.go`（主协调器）<br>`kvblock_scorer.go`（Pod 打分器）<br>`kvblock/index.go`（索引接口）<br>`kvevents/pool.go`（事件处理池） | 13 个 .go 文件 |
| **pkg/tokenization/** | Tokenization 池与缓存 | `pool.go`（Worker Pool）<br>`tokenizer.go`（HF Tokenizer 封装）<br>`prefixstore/lru_store.go`（前缀缓存） | 8 个 .go 文件 |
| **pkg/preprocessing/** | 聊天模板预处理（CGO） | `chat_completions/cgo_functions.go`<br>`chat_completions/render_jinja_template_wrapper.py` | 5 个文件 |
| **pkg/utils/** | 通用工具函数 | `slices.go`（切片操作）<br>`logging/levels.go`（日志级别） | 3 个 .go 文件 |
| **examples/** | 示例程序（3 个入口） | `kv_events/online/main.go`（生产参考）<br>`kv_events/offline/main.go`（测试用）<br>`kv_cache_index/main.go`（快速验证） | 6 个 .go 文件 |
| **tests/e2e/** | 端到端测试 | `e2e_test.go`（集成测试） | 2 个 .go 文件 |
| **deploy/** | Kubernetes 部署配置 | `kustomization.yaml`<br>`common/` | Kustomize 资源 |
| **vllm-setup-helm/** | vLLM Helm Chart | `values.yaml`<br>`templates/` | Helm 模板 |
| **benchmarking/** | 性能基准测试 | Tokenization、聊天模板基准 | Python 脚本 |
| **docs/** | 项目文档 | `architecture.md`<br>`configuration.md` | Markdown 文档 |
| **hack/** | 构建工具脚本 | 工具安装、版本管理 | Shell 脚本 |
| **hooks/** | Git 钩子 | `pre-commit`（代码检查） | Shell 脚本 |

**关键指标**：
- **Go 源文件总数**：32 个
- **核心代码行数**：~8000 行（不含测试）
- **测试覆盖率**：覆盖核心模块
- **外部依赖**：15+ Go 模块，1 个 Python 库（transformers）

---

## 三、系统启动流程图

### 3.1 完整启动流程（Online 服务）

```mermaid
graph TD
    Start([程序启动: main]) --> SignalHandler[设置信号处理<br>SIGINT/SIGTERM]
    SignalHandler --> CheckPythonPath{检查 PYTHONPATH}

    CheckPythonPath -->|未设置| ErrorExit[返回错误并退出]
    CheckPythonPath -->|已设置| InitPython[初始化 Python 解释器]

    InitPython --> CGOInit["C.Py_InitializeGo()<br>C.Py_InitChatTemplateModule()"]
    CGOInit --> CreateIndexer[创建 KV-Cache Indexer]

    CreateIndexer --> Component1[创建 5 个核心组件]
    Component1 --> PrefixStore["1. prefixstore.LRUTokenStore<br>(Token 前缀缓存)"]
    PrefixStore --> TokenProc["2. kvblock.TokenProcessor<br>(Token → Keys 转换)"]
    TokenProc --> IndexBackend["3. kvblock.Index<br>(索引后端选择)"]

    IndexBackend --> BackendChoice{选择后端}
    BackendChoice -->|InMemory| InMemory[InMemoryIndex<br>双层 LRU]
    BackendChoice -->|Redis| Redis[RedisIndex<br>redis.NewClient]
    BackendChoice -->|CostAware| CostAware[CostAwareMemoryIndex<br>ristretto.Cache]

    InMemory --> Scorer
    Redis --> Scorer
    CostAware --> Scorer

    Scorer["4. KVBlockScorer<br>(最长前缀打分)"]
    Scorer --> TokenPool["5. tokenization.Pool<br>(Worker Pool × 5)"]

    TokenPool --> RunIndexer["启动后台协程<br>go indexer.Run(ctx)"]
    RunIndexer --> CreateEventPool[创建事件处理池]

    CreateEventPool --> EventQueue["创建分片队列 × 4<br>FNV-1a 哈希分片"]
    EventQueue --> ZMQSub["创建 ZMQ 订阅器<br>socket.Connect(tcp://localhost:5557)"]
    ZMQSub --> StartWorkers["启动 Worker 协程<br>go worker(ctx, i)"]

    StartWorkers --> StartZMQ["启动 ZMQ 订阅器<br>go subscriber.Start(ctx)"]
    StartZMQ --> SetupHTTP[设置 HTTP 服务]

    SetupHTTP --> RegisterAPI1["注册 /score_completions"]
    RegisterAPI1 --> RegisterAPI2["注册 /score_chat_completions"]
    RegisterAPI2 --> StartHTTP["启动 HTTP 服务器<br>go server.ListenAndServe()"]

    StartHTTP --> Ready[🟢 服务就绪<br>监听 :8080]
    Ready --> Wait["等待关闭信号<br>&lt;-ctx.Done()"]

    Wait --> Shutdown[优雅关闭]
    Shutdown --> ShutHTTP["httpServer.Shutdown(30s)"]
    ShutHTTP --> FinalizePython["chatProcessor.Finalize()<br>(释放 Python 资源)"]
    FinalizePython --> Exit([程序退出])

    style Start fill:#e1f5ff
    style Ready fill:#c8e6c9
    style ErrorExit fill:#ffcdd2
    style Exit fill:#fff9c4
```

### 3.2 关键启动步骤说明

| 步骤 | 组件 | 耗时 | 可能失败点 | 恢复方式 |
|------|------|------|-----------|----------|
| **1. PYTHONPATH 检查** | 环境变量验证 | <1ms | 未设置 | 返回错误并退出 |
| **2. Python 初始化** | CGO → `Py_Initialize()` | 50-100ms | Python 库缺失 | 错误日志 + 退出 |
| **3. Indexer 创建** | 5 个子组件初始化 | 10-50ms | 内存不足 | 错误日志 + 退出 |
| **4. 索引后端选择** | InMemory / Redis / CostAware | 5-20ms | Redis 连接失败 | 错误日志 + 退出 |
| **5. 事件池启动** | 分片队列 + ZMQ 订阅 | 10-30ms | ZMQ 连接失败 | 错误日志 + 继续（会重试） |
| **6. HTTP 服务器** | Goroutine 启动 | <5ms | 端口占用 | 错误日志 + 退出 |

**总启动时间**：75-205ms（正常情况）

---

## 四、核心调用链时序图

### 4.1 读取路径：Pod 评分时序图

```mermaid
sequenceDiagram
    participant Client as Scheduler/Router
    participant HTTP as HTTP Handler
    participant Indexer as kvcache.Indexer
    participant Pool as tokenization.Pool
    participant Worker as Pool Worker
    participant PrefixStore as LRUTokenStore
    participant Tokenizer as HFTokenizer
    participant Processor as TokenProcessor
    participant Index as kvblock.Index
    participant Scorer as KVBlockScorer

    Client->>HTTP: POST /score_completions<br>{prompt, model}
    activate HTTP
    HTTP->>HTTP: 解析 JSON 请求体
    HTTP->>Indexer: GetPodScores(ctx, prompt, model, nil)
    activate Indexer

    Note over Indexer: 步骤 1: Tokenization
    Indexer->>Pool: Tokenize(prompt, model)
    activate Pool
    Pool->>Pool: 创建 resultCh，加入队列
    Pool-->>Worker: 异步任务分发
    activate Worker

    Worker->>PrefixStore: FindLongestContainedTokens(prompt, model)
    activate PrefixStore
    PrefixStore->>PrefixStore: 分块哈希 (xxhash)
    PrefixStore->>PrefixStore: LRU.Get(blockHash)
    PrefixStore-->>Worker: (tokens, overlapRatio=0.3)
    deactivate PrefixStore

    alt overlapRatio < 0.8 (缓存未命中)
        Worker->>Tokenizer: Encode(prompt, model)
        activate Tokenizer
        Tokenizer->>Tokenizer: LRU 查找 Tokenizer
        Tokenizer->>Tokenizer: [未命中] FromPretrained(model)
        Tokenizer-->>Worker: (tokens, offsets, nil)
        deactivate Tokenizer

        Worker->>PrefixStore: AddTokenization(model, prompt, tokens, offsets)
        activate PrefixStore
        PrefixStore->>PrefixStore: 🔒 Lock, 更新缓存
        deactivate PrefixStore
    end

    Worker->>Pool: resultCh <- tokens
    deactivate Worker
    Pool-->>Indexer: tokens []uint32
    deactivate Pool

    Note over Indexer: 步骤 2: Token → KV-Block Keys
    Indexer->>Processor: TokensToKVBlockKeys(tokens, model)
    activate Processor
    Processor->>Processor: chunkTokens(blockSize=16)
    loop 每个 chunk
        Processor->>Processor: hash(parent, chunk, nil)<br>SHA-256(CBOR([parent, tokens]))
    end
    Processor-->>Indexer: blockKeys []Key
    deactivate Processor

    Note over Indexer: 步骤 3: 索引查询
    Indexer->>Index: Lookup(ctx, blockKeys, podSet)
    activate Index
    Index->>Index: 🔒 RLock (InMemory)
    Index->>Index: data.Get(key) → podCache
    Index-->>Indexer: keyToPods map[Key][]PodID
    deactivate Index

    Note over Indexer: 步骤 4: Pod 打分
    Indexer->>Scorer: Score(blockKeys, keyToPods)
    activate Scorer
    Scorer->>Scorer: activePods = pods[keys[0]]
    loop keys[1:] (最长连续前缀)
        Scorer->>Scorer: activePods = activePods ∩ pods[key]
        Scorer->>Scorer: podScores[pod]++
    end
    Scorer-->>Indexer: podScores map[PodID]int
    deactivate Scorer

    Indexer-->>HTTP: podScores
    deactivate Indexer
    HTTP->>HTTP: json.Marshal(podScores)
    HTTP-->>Client: {"pod1": 10, "pod2": 5}
    deactivate HTTP
```

**性能指标**：
- **总延迟**：6-61ms（缓存命中时 ≤ 12ms）
- **瓶颈**：Tokenization（5-50ms）
- **优化**：Token 前缀缓存（目标 80% 命中率）

---

### 4.2 写入路径：事件处理时序图

```mermaid
sequenceDiagram
    participant vLLM as vLLM Pod
    participant Subscriber as ZMQ Subscriber
    participant Pool as kvevents.Pool
    participant Queue as Workqueue[i]
    participant Worker as Pool Worker
    participant Index as kvblock.Index

    Note over vLLM: 创建/删除 KV-Block
    vLLM->>Subscriber: ZMQ Pub<br>Topic: "kv@pod1@model"<br>Payload: EventBatch (msgpack)
    activate Subscriber
    Subscriber->>Subscriber: socket.RecvMessageBytes()
    Subscriber->>Subscriber: 解析 topic → {PodID, Model}
    Subscriber->>Pool: AddTask(Message{Topic, Payload, PodID})
    deactivate Subscriber

    activate Pool
    Pool->>Pool: FNV-1a(PodID) → hash
    Pool->>Pool: queueIndex = hash % 4
    Pool->>Queue: queues[queueIndex].Add(msg)
    deactivate Pool

    activate Queue
    Queue-->>Worker: msg *Message
    deactivate Queue

    activate Worker
    Worker->>Worker: processEvent(ctx, msg)
    Worker->>Worker: msgpack.Unmarshal(payload, &EventBatch)

    alt Unmarshal 失败 (毒丸消息)
        Worker->>Worker: 记录错误日志
        Worker->>Worker: 丢弃消息 (防止无限重试)
    else Unmarshal 成功
        Worker->>Worker: 解析 Tagged Union: [tag, ...fields]

        alt tag = "BlockStored"
            Worker->>Worker: Unmarshal → BlockStored{BlockHashes, ...}
            Worker->>Index: Add(ctx, keys, []PodEntry{pod, tier})
            activate Index
            alt InMemoryIndex
                Index->>Index: 🔒 Lock
                Index->>Index: podCache[key].Add(entry)
                Index->>Index: 🔒 Unlock
            else RedisIndex
                Index->>Index: redis.Pipeline()
                Index->>Index: pipe.HSet(key, pod@tier, timestamp)
                Index->>Index: pipe.Exec() (单次 RTT)
            end
            Index-->>Worker: nil (success)
            deactivate Index

        else tag = "BlockRemoved"
            Worker->>Worker: Unmarshal → BlockRemoved{BlockHashes}
            Worker->>Index: Evict(ctx, keys, []PodEntry{pod, tier})
            activate Index
            Index->>Index: podCache[key].Remove(entry)
            Index-->>Worker: nil (success)
            deactivate Index

        else tag = "AllBlocksCleared"
            Worker->>Worker: 遍历所有 keys
            loop 每个 key
                Worker->>Index: Evict(ctx, key, []PodEntry{pod, tier})
            end
        end
    end

    Worker->>Queue: queue.Forget(msg) → 成功处理
    deactivate Worker
```

**性能指标**：
- **总延迟**：2-7ms
- **吞吐量**：~1000 events/sec/worker
- **并发能力**：4 个 Worker（可配置）

---

## 五、模块依赖关系图

### 5.1 分层依赖关系

```mermaid
graph TD
    subgraph "L1: Presentation Layer"
        A1[HTTP Handler]
    end

    subgraph "L2: Application Layer"
        B1[kvcache.Indexer]
        B2[ChatTemplatingProcessor]
    end

    subgraph "L3: Service Layer"
        C1[tokenization.Pool]
        C2[kvblock.TokenProcessor]
        C3[KVBlockScorer]
        C4[kvevents.Pool]
        C5[kvevents.ZMQSubscriber]
    end

    subgraph "L4: Data Layer"
        D1[prefixstore.LRUTokenStore]
        D2[CachedHFTokenizer]
        D3[kvblock.Index Interface]
    end

    subgraph "L5: Storage Layer"
        E1[InMemoryIndex]
        E2[RedisIndex]
        E3[CostAwareMemoryIndex]
    end

    subgraph "L6: Infrastructure"
        F1[metrics.Collector]
        F2[utils.logging]
    end

    subgraph "L7: External Dependencies"
        G1[vLLM Fleet]
        G2[Redis Server]
        G3[HuggingFace Hub]
        G4[Python Interpreter]
    end

    A1 --> B1
    A1 --> B2
    B1 --> C1
    B1 --> C2
    B1 --> C3
    B2 --> G4

    C1 --> D1
    C1 --> D2
    C2 --> D3
    C3 --> D3

    C4 --> D3
    C5 --> C4
    G1 --> C5

    D3 -.->|Implementation| E1
    D3 -.->|Implementation| E2
    D3 -.->|Implementation| E3

    E2 --> G2
    D2 --> G3

    E1 -.->|Optional| F1
    E2 -.->|Optional| F1
    E3 -.->|Optional| F1

    B1 -.->|Uses| F2
    C1 -.->|Uses| F2
    C4 -.->|Uses| F2

    style A1 fill:#e1f5ff
    style B1 fill:#fff9c4
    style D3 fill:#c8e6c9
    style G1 fill:#ffccbc
```

### 5.2 依赖关系矩阵

| 模块 | 依赖的内部模块 | 依赖的外部库 | 依赖的外部系统 |
|------|--------------|-------------|--------------|
| **HTTP Handler** | `kvcache.Indexer`<br>`ChatTemplatingProcessor` | `net/http`<br>`encoding/json` | - |
| **kvcache.Indexer** | `tokenization.Pool`<br>`kvblock.TokenProcessor`<br>`KVBlockScorer`<br>`kvblock.Index` | `k8s.io/klog/v2` | - |
| **tokenization.Pool** | `prefixstore.LRUTokenStore`<br>`CachedHFTokenizer` | `k8s.io/client-go/util/workqueue` | - |
| **CachedHFTokenizer** | - | `github.com/daulet/tokenizers`<br>`golang.org/x/sync/singleflight` | HuggingFace Hub |
| **kvblock.TokenProcessor** | - | `crypto/sha256`<br>`github.com/fxamacker/cbor/v2` | - |
| **kvevents.Pool** | `kvevents.ZMQSubscriber`<br>`kvblock.Index` | `k8s.io/client-go/util/workqueue`<br>`hash/fnv` | - |
| **kvevents.ZMQSubscriber** | - | `github.com/pebbe/zmq4`<br>`github.com/vmihailenco/msgpack/v5` | vLLM Fleet (ZMQ) |
| **InMemoryIndex** | - | `github.com/hashicorp/golang-lru/v2` | - |
| **RedisIndex** | - | `github.com/redis/go-redis/v9` | Redis Server |
| **CostAwareMemoryIndex** | - | `github.com/dgraph-io/ristretto/v2` | - |
| **ChatTemplatingProcessor** | - | `CGO`<br>`encoding/json` | Python 3.12 + transformers |

---

## 六、外部依赖详解

### 6.1 运行时依赖

#### 6.1.1 vLLM Fleet（ZMQ Publisher）

**依赖类型**：事件源

**连接方式**：
```
Protocol: ZMQ Pub-Sub
Endpoint: tcp://<vllm-service>:5557 (默认)
Topic Format: kv@<pod-id>@<model>
Message Format: Msgpack (EventBatch)
```

**事件类型**：
1. **BlockStored**：KV-Block 创建
2. **BlockRemoved**：KV-Block 删除
3. **AllBlocksCleared**：清空所有 Block

**配置项**（环境变量）：
- `ZMQ_ENDPOINT`：ZMQ 服务地址（默认 `tcp://localhost:5557`）
- `ZMQ_TOPIC`：订阅主题前缀（默认 `kv@`）

**容错机制**：
- ZMQ 自动重连（秒级）
- 毒丸消息丢弃 + 日志
- 事件顺序保证（FNV-1a 哈希分片）

**部署要求**：
- vLLM 版本：支持 KVEvents 的版本
- `PYTHONHASHSEED` 对齐：必须与 KV-Cache Manager 一致

---

#### 6.1.2 Redis Server（可选）

**依赖类型**：分布式存储后端

**连接方式**：
```
Protocol: Redis Protocol
Address: redis://user:pass@host:port/db
Client: github.com/redis/go-redis/v9
```

**数据结构**：
```redis
# Key 格式
"<model>@<chunk_hash>"

# 类型
Hash

# Fields
"<pod_id>@<device_tier>" -> "<timestamp>"
```

**配置项**（JSON）：
```json
{
  "kvBlockIndexConfig": {
    "redisConfig": {
      "address": "redis://127.0.0.1:6379"
    }
  }
}
```

**性能优化**：
- Pipeline 批量操作（减少 RTT）
- TTL 设置（自动清理过期条目）

**部署要求**：
- Redis 版本：6.0+
- 内存：根据索引大小（建议 ≥ 4GB）
- 持久化：可选（RDB/AOF）

**适用场景**：
- ✅ 多副本部署（共享索引）
- ✅ 需要持久化
- ❌ 单机部署（内存后端更快）

---

#### 6.1.3 HuggingFace Hub

**依赖类型**：Tokenizer 模型下载

**连接方式**：
```
Protocol: HTTPS
Endpoint: https://huggingface.co/<model>/resolve/main/tokenizer.json
Client: github.com/daulet/tokenizers (Rust binding)
```

**认证**：
- 环境变量：`HF_TOKEN`（私有模型需要）
- 配置项：`TokenizersPoolConfig.HuggingFaceToken`

**缓存策略**：
- **本地缓存**：`~/.cache/huggingface/tokenizers/` 或自定义目录
- **内存缓存**：LRU（容量 20 个模型）
- **Singleflight**：防止重复下载

**配置项**（JSON）：
```json
{
  "tokenizersPoolConfig": {
    "huggingFaceToken": "hf_xxxxx",
    "tokenizersCacheDir": "/data/tokenizers"
  }
}
```

**离线部署**：
- 预下载 Tokenizer 到本地目录
- 挂载到容器：`-v /data/tokenizers:/app/tokenizers`

---

#### 6.1.4 Python 3.12 + transformers

**依赖类型**：聊天模板渲染（CGO）

**Python 库**：
```
transformers>=4.45.0
```

**CGO 调用流程**：
```
Go → C (CString) → Python (json.loads) → transformers.render_jinja_template() → C (char*) → Go (string)
```

**环境要求**：
- **Python 版本**：3.12（严格）
- **开发头文件**：`python3.12-dev`（Linux）或 `python@3.12`（macOS）
- **PYTHONPATH**：必须包含 `pkg/preprocessing/chat_completions/` 和 venv

**配置项**（环境变量）：
```bash
export PYTHONPATH=$(pwd)/pkg/preprocessing/chat_completions:$(pwd)/build/venv/lib/python3.12/site-packages
```

**初始化**：
```go
// pkg/preprocessing/chat_completions/cgo_functions.go:94
processor := NewChatTemplatingProcessor()
processor.Initialize() // 启动 Python 解释器
defer processor.Finalize() // 释放资源
```

**性能影响**：
- 初始化：50-100ms（一次性）
- 单次调用：1-5ms（JSON 序列化 + CGO）

---

### 6.2 构建依赖

#### 6.2.1 HuggingFace Tokenizer 绑定

**类型**：静态库

**下载方式**：
```bash
make download-tokenizer
```

**位置**：
```
lib/libtokenizers.a
lib/libtokenizers.h
```

**版本**：从 Dockerfile 读取（`ARG RELEASE_VERSION`）

**平台支持**：
- Linux: amd64, arm64
- macOS: amd64 (Intel), arm64 (M1/M2)

---

#### 6.2.2 ZMQ 库

**类型**：动态库

**安装方式**：
```bash
# Linux
apt install libzmq3-dev

# macOS
brew install zeromq
```

**验证**：
```bash
pkg-config --exists libzmq && echo "✅ ZMQ installed"
```

---

### 6.3 外部依赖总结表

| 依赖项 | 类型 | 必需/可选 | 默认配置 | 备选方案 |
|--------|------|----------|---------|----------|
| **vLLM Fleet** | 事件源 | 必需 | `tcp://localhost:5557` | 无（核心依赖） |
| **Redis** | 存储 | 可选 | - | InMemory / CostAware |
| **HuggingFace Hub** | 模型下载 | 可选 | 在线下载 | 离线预下载 |
| **Python 3.12** | 运行时 | 可选 | 无 | 跳过聊天模板功能 |
| **ZMQ 库** | 运行时 | 必需 | 系统安装 | 无（核心依赖） |
| **Tokenizer 绑定** | 构建 | 必需 | 自动下载 | 无（核心依赖） |

---

## 七、配置项详解

### 7.1 配置文件结构

**配置格式**：JSON

**加载方式**：
1. **代码方式**：直接构造 `kvcache.Config` 结构体
2. **环境变量**：通过环境变量覆盖默认值
3. **JSON 文件**：加载 JSON 配置文件（需自行实现）

---

### 7.2 核心配置项

#### 7.2.1 KV-Cache Indexer 配置

**完整示例**：
```json
{
  "prefixStoreConfig": {
    "cacheSize": 500000,
    "blockSize": 256
  },
  "tokenProcessorConfig": {
    "blockSize": 16,
    "hashSeed": ""
  },
  "kvBlockIndexConfig": {
    "inMemoryConfig": {
      "size": 100000000,
      "podCacheSize": 10
    },
    "enableMetrics": true,
    "metricsLoggingInterval": "30s"
  },
  "tokenizersPoolConfig": {
    "workersCount": 5,
    "minPrefixOverlapRatio": 0.8,
    "huggingFaceToken": "",
    "tokenizersCacheDir": ""
  }
}
```

**关键参数调优**：

| 参数 | 默认值 | 推荐范围 | 影响 |
|------|--------|---------|------|
| `prefixStoreConfig.cacheSize` | 500000 | 100K-1M | Token 前缀缓存容量 |
| `prefixStoreConfig.blockSize` | 256 | 128-512 | 每块字符数（字节） |
| `tokenProcessorConfig.blockSize` | 16 | 16 | **必须**与 vLLM 一致 |
| `tokenProcessorConfig.hashSeed` | `""` | 与 vLLM 对齐 | **必须**与 `PYTHONHASHSEED` 一致 |
| `kvBlockIndexConfig.inMemoryConfig.size` | 1e8 | 1e7-1e9 | 索引容量（Key 数量） |
| `kvBlockIndexConfig.inMemoryConfig.podCacheSize` | 10 | 5-20 | 每个 Key 的 Pod 数量 |
| `tokenizersPoolConfig.workersCount` | 5 | 4-16 | Tokenization 并发数 |
| `tokenizersPoolConfig.minPrefixOverlapRatio` | 0.8 | 0.5-0.9 | 缓存命中阈值 |

---

#### 7.2.2 索引后端配置

**In-Memory（默认）**：
```json
{
  "kvBlockIndexConfig": {
    "inMemoryConfig": {
      "size": 100000000,
      "podCacheSize": 10
    }
  }
}
```

**特点**：
- ✅ 最快（纯内存）
- ✅ 无外部依赖
- ❌ 不支持多副本共享
- ❌ 重启后数据丢失

**适用场景**：单机部署、测试环境

---

**Cost-Aware Memory**：
```json
{
  "kvBlockIndexConfig": {
    "costAwareMemoryConfig": {
      "size": "2GiB"
    }
  }
}
```

**特点**：
- ✅ 内存感知淘汰
- ✅ 动态成本计算
- ⚠️ 性能略低于 InMemory

**适用场景**：内存受限环境

---

**Redis**：
```json
{
  "kvBlockIndexConfig": {
    "redisConfig": {
      "address": "redis://user:pass@redis:6379/0"
    }
  }
}
```

**特点**：
- ✅ 多副本共享
- ✅ 可持久化
- ❌ 网络延迟（Pipeline 优化后 <10ms）

**适用场景**：多副本部署、需要持久化

---

#### 7.2.3 事件处理池配置

**完整示例**：
```json
{
  "zmqEndpoint": "tcp://vllm-service:5557",
  "topicFilter": "kv@",
  "concurrency": 4
}
```

**关键参数**：

| 参数 | 默认值 | 推荐范围 | 影响 |
|------|--------|---------|------|
| `zmqEndpoint` | `tcp://*:5557` | - | ZMQ 订阅地址 |
| `topicFilter` | `kv@` | - | 订阅主题前缀 |
| `concurrency` | 4 | 2-8 | Worker 数量（事件并发） |

**并发数选择**：
- **vLLM Pod < 10**：concurrency = 2
- **vLLM Pod 10-50**：concurrency = 4
- **vLLM Pod > 50**：concurrency = 8

---

### 7.3 环境变量配置

**Online 服务专用**：

| 环境变量 | 默认值 | 必需/可选 | 用途 |
|---------|--------|----------|------|
| `PYTHONPATH` | - | **必需** | Python 模块搜索路径 |
| `HF_TOKEN` | - | 可选 | HuggingFace API Token |
| `PYTHONHASHSEED` | - | **必需** | Python 哈希种子（与 vLLM 对齐） |
| `BLOCK_SIZE` | 16 | 可选 | KV-Block 大小 |
| `ZMQ_ENDPOINT` | `tcp://localhost:5557` | 可选 | ZMQ 订阅地址 |
| `ZMQ_TOPIC` | `kv@` | 可选 | ZMQ 订阅主题 |
| `POOL_CONCURRENCY` | 4 | 可选 | 事件处理并发数 |
| `HTTP_PORT` | 8080 | 可选 | HTTP 服务端口 |
| `REDIS_ADDR` | - | 可选 | Redis 连接地址 |

**配置示例**：
```bash
# 必需配置
export PYTHONPATH=$(pwd)/pkg/preprocessing/chat_completions:$(pwd)/build/venv/lib/python3.12/site-packages
export PYTHONHASHSEED=0

# 可选配置
export HF_TOKEN=hf_xxxxx
export ZMQ_ENDPOINT=tcp://vllm-service:5557
export POOL_CONCURRENCY=8
export HTTP_PORT=9090
export REDIS_ADDR=redis://redis:6379
```

---

### 7.4 配置最佳实践

#### 7.4.1 开发环境配置

```json
{
  "prefixStoreConfig": {"cacheSize": 100000, "blockSize": 256},
  "tokenProcessorConfig": {"blockSize": 16, "hashSeed": "0"},
  "kvBlockIndexConfig": {
    "inMemoryConfig": {"size": 10000000, "podCacheSize": 5},
    "enableMetrics": true,
    "metricsLoggingInterval": "10s"
  },
  "tokenizersPoolConfig": {
    "workersCount": 2,
    "minPrefixOverlapRatio": 0.7
  }
}
```

**特点**：
- 小内存占用
- 快速指标反馈
- 低并发数

---

#### 7.4.2 生产环境配置

```json
{
  "prefixStoreConfig": {"cacheSize": 1000000, "blockSize": 256},
  "tokenProcessorConfig": {"blockSize": 16, "hashSeed": "0"},
  "kvBlockIndexConfig": {
    "redisConfig": {"address": "redis://redis:6379"},
    "enableMetrics": true,
    "metricsLoggingInterval": "1m0s"
  },
  "tokenizersPoolConfig": {
    "workersCount": 8,
    "minPrefixOverlapRatio": 0.85,
    "tokenizersCacheDir": "/data/tokenizers"
  }
}
```

**特点**：
- Redis 后端（多副本支持）
- 高并发数（Worker × 8）
- 大缓存容量

---

#### 7.4.3 高负载场景配置

```json
{
  "prefixStoreConfig": {"cacheSize": 2000000, "blockSize": 512},
  "tokenProcessorConfig": {"blockSize": 16, "hashSeed": "0"},
  "kvBlockIndexConfig": {
    "costAwareMemoryConfig": {"size": "8GiB"},
    "enableMetrics": true
  },
  "tokenizersPoolConfig": {
    "workersCount": 16,
    "minPrefixOverlapRatio": 0.9
  }
}
```

**环境变量**：
```bash
export POOL_CONCURRENCY=16
export ZMQ_ENDPOINT=tcp://vllm-service:5557
```

**特点**：
- 成本感知后端（内存高效）
- 极高并发（Worker × 16）
- 大 Token 前缀块（512 字节）

---

## 八、部署架构

### 8.1 单机部署

```
┌─────────────────────────────────────────┐
│         KV-Cache Manager                │
│  ┌──────────────────────────────────┐   │
│  │  HTTP Server (:8080)             │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │  kvcache.Indexer                 │   │
│  │  - InMemoryIndex (双层 LRU)      │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │  kvevents.Pool (Worker × 4)      │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
         ↑ ZMQ                  ↑ HTTP
         │                      │
┌────────┴────────┐    ┌────────┴────────┐
│  vLLM Pod 1     │    │   Scheduler     │
│  vLLM Pod 2     │    └─────────────────┘
│  ...            │
└─────────────────┘
```

**特点**：
- ✅ 部署简单
- ✅ 低延迟（无网络 I/O）
- ❌ 单点故障
- ❌ 无法水平扩展

**适用场景**：测试、小规模部署（< 10 vLLM Pods）

---

### 8.2 多副本部署（共享 Redis）

```
                  ┌─────────────────┐
                  │  Load Balancer  │
                  └────────┬────────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                │
┌─────────▼─────┐  ┌───────▼──────┐  ┌──────▼──────┐
│  Manager 1    │  │  Manager 2   │  │  Manager 3  │
│  :8080        │  │  :8080       │  │  :8080      │
└───────┬───────┘  └───────┬──────┘  └──────┬──────┘
        │                  │                │
        └──────────────────┼────────────────┘
                           │
                  ┌────────▼────────┐
                  │  Redis Cluster  │
                  │  (Shared Index) │
                  └─────────────────┘

        ┌────────────────────────────┐
        │  vLLM Fleet (ZMQ Pub)      │
        │  - Pod 1, Pod 2, ...       │
        └────────────────────────────┘
```

**特点**：
- ✅ 高可用（多副本）
- ✅ 水平扩展
- ✅ 共享索引（一致性）
- ❌ Redis 成为单点（需 Redis Cluster）

**适用场景**：生产环境、大规模部署（> 50 vLLM Pods）

**Redis 配置**：
```bash
# Redis Sentinel (高可用)
redis-sentinel --sentinel

# Redis Cluster (分片)
redis-cluster create --replicas 1
```

---

### 8.3 Kubernetes 部署

**部署清单**：
```bash
kustomize build deploy | kubectl apply -f -
```

**关键资源**：
- **Deployment**：KV-Cache Manager（3 副本）
- **Service**：ClusterIP (:8080)
- **ConfigMap**：配置文件
- **Secret**：HF_TOKEN、Redis 密码

**YAML 示例**：
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kv-cache-manager
spec:
  replicas: 3
  selector:
    matchLabels:
      app: kv-cache-manager
  template:
    metadata:
      labels:
        app: kv-cache-manager
    spec:
      containers:
      - name: manager
        image: ghcr.io/llm-d/kv-cache-manager:latest
        env:
        - name: PYTHONPATH
          value: "/app/pkg/preprocessing/chat_completions:/app/venv/lib/python3.12/site-packages"
        - name: ZMQ_ENDPOINT
          value: "tcp://vllm-service:5557"
        - name: REDIS_ADDR
          value: "redis://redis:6379"
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "2Gi"
            cpu: "1"
          limits:
            memory: "4Gi"
            cpu: "2"
```

---

## 九、监控与可观测性

### 9.1 日志级别

| 级别 | klog 参数 | 内容 | 示例 |
|------|----------|------|------|
| **INFO** | `-v=0` | 启动、关闭、错误 | `"HTTP server running on :8080"` |
| **DEBUG** | `-v=4` | 事件处理详情 | `"Processing event, topic=kv@pod1@model"` |
| **TRACE** | `-v=5` | Token、Keys、Scores | `"found tokens, tokens=[1,2,3], block-keys=[...]"` |

**配置方式**：
```bash
# 启动时设置
go run main.go -v=5

# Docker
docker run -it kv-cache-manager:latest -v=4
```

---

### 9.2 Prometheus 指标（可选）

**启用方式**：
```json
{
  "kvBlockIndexConfig": {
    "enableMetrics": true,
    "metricsLoggingInterval": "30s"
  }
}
```

**指标列表**：

| 指标名称 | 类型 | 描述 |
|---------|------|------|
| `kvcache_index_lookup_duration_seconds` | Histogram | 索引查询延迟 |
| `kvcache_index_hits_total` | Counter | 缓存命中次数 |
| `kvcache_index_misses_total` | Counter | 缓存未命中次数 |
| `kvcache_index_evictions_total` | Counter | 缓存淘汰次数 |

**Prometheus 配置**（需自行实现 `/metrics` 端点）：
```yaml
scrape_configs:
  - job_name: 'kv-cache-manager'
    static_configs:
      - targets: ['manager:8080']
```

---

### 9.3 健康检查

**Liveness Probe**：
```yaml
livenessProbe:
  httpGet:
    path: /score_completions
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 30
```

**Readiness Probe**：
```yaml
readinessProbe:
  httpGet:
    path: /score_completions
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
```

---

## 十、故障排查

### 10.1 常见问题

| 问题 | 症状 | 排查步骤 | 解决方案 |
|------|------|---------|----------|
| **哈希不匹配** | Pod 得分始终为 0 | 1. 检查 `PYTHONHASHSEED`<br>2. 对比 vLLM 配置 | 对齐环境变量 |
| **事件顺序错乱** | 索引状态不一致 | 查看 Worker 日志 | 确认 FNV-1a 哈希分片 |
| **Redis 连接失败** | HTTP 500 错误 | `redis-cli ping` | 检查网络/密码 |
| **Python 初始化失败** | 聊天模板 500 错误 | `python3.12 --version`<br>`pip show transformers` | 安装依赖 |
| **Tokenization 慢** | 请求延迟 > 50ms | 检查 PrefixStore 命中率 | 增大缓存容量 |

---

### 10.2 调试技巧

**启用 TRACE 日志**：
```bash
go run main.go -v=5 2>&1 | grep "TRACE"
```

**查看 Redis 索引**：
```bash
redis-cli
> HGETALL "meta-llama/Llama-2-7b-hf@12345678"
```

**性能分析**：
```bash
# CPU Profile
go test -cpuprofile=cpu.prof -bench=. ./pkg/kvcache/

# 分析
go tool pprof cpu.prof
```

---

## 十一、总结

### 11.1 架构亮点

1. **分层清晰**：Presentation → Application → Service → Data → Storage（5 层）
2. **可插拔设计**：索引后端、打分策略、缓存实现均可替换
3. **高性能**：4 层缓存 + Worker Pool + Pipeline 优化
4. **容错健壮**：毒丸处理、优雅降级、ZMQ 自动重连
5. **兼容性强**：与 vLLM 哈希算法完全对齐

### 11.2 技术栈总览

| 类别 | 技术选型 | 理由 |
|------|---------|------|
| **编程语言** | Go 1.24.1 | 高并发、易部署 |
| **消息队列** | ZMQ | 低延迟、高吞吐 |
| **缓存** | LRU / Ristretto | 内存高效 |
| **序列化** | Msgpack / CBOR / JSON | 兼容 vLLM、高效 |
| **分布式存储** | Redis | 多副本支持 |
| **Tokenization** | HuggingFace Tokenizers (Rust) | 高性能 |
| **聊天模板** | Python transformers (CGO) | 兼容性 |

### 11.3 关键指标

- **读取延迟**：6-61ms（缓存命中时 ≤ 12ms）
- **写入延迟**：2-7ms
- **并发能力**：Tokenization × 5, Events × 4
- **缓存层次**：4 层 LRU
- **索引容量**：1e8 个 Key（默认）
- **启动时间**：75-205ms
