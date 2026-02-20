# Tactical CLI Architecture

> 策略：不 fork，不 rename，直接在 kimi-cli 上做增量扩展。
> 保持 `kimi_cli` 包名和全部现有代码不动，只新增模块和扩展已有接口。

## 扩展点总览

```
kimi-cli (原样保留)
│
├── 扩展 1: Sandbox ──── tools/sandbox/     (新增 3 个文件)
│   Shell tool 改为通过 SandboxExecutor 执行
│
├── 扩展 2: LLM ──────── llm.py             (改 1 处: 加 "custom" provider type)
│   config.toml 配置任意 OpenAI 兼容端点
│
├── 扩展 3: Auth ──────── ui/shell/setup.py  (改 1 处: 加 API key 路径)
│   首次启动支持 OAuth 或 API Key 二选一
│
├── 扩展 4: Session ───── session.py         (改 1 处: 加 metadata 字段)
│
├── 扩展 5: Plugins ───── plugins/           (新增 1 个文件)
│   外部 tool 插件自动发现
│
└── 扩展 6: Brand ──────── constant.py + prompt.py (改几行常量)
```

## 新增文件清单 (共 4 个)

```
src/kimi_cli/
├── tools/sandbox/
│   ├── __init__.py      SandboxExecutor protocol + ExecResult
│   ├── local.py         LocalExecutor (直接 subprocess，现有行为)
│   └── docker.py        DockerSandboxExecutor (容器隔离)
└── plugins/
    └── __init__.py      discover_and_load_plugins()
```

## 修改文件清单 (共 7 个)

| 文件 | 改动 | 行数估算 |
|------|------|---------|
| `config.py` | 加 `SandboxConfig` 类 + `sandbox` 字段 | +10 行 |
| `llm.py` | `create_llm()` 加 `"custom"` 分支 | +15 行 |
| `tools/shell/__init__.py` | exec 改走 `SandboxExecutor` | ~20 行改动 |
| `soul/agent.py` | `Runtime` 加 `sandbox` 字段 | +2 行 |
| `session.py` | 加 `SessionMetadata` 类 | +20 行 |
| `ui/shell/setup.py` | `setup_platform()` 加 API key 分支 | +40 行 |
| `constant.py` | 改 `NAME`、`USER_AGENT` | 2 行 |

**总计**：4 个新文件 + 7 个文件的小改动，约 200 行新代码。

## 各扩展点设计

### 1. Sandbox

不改 Kimi CLI 的 Approval 机制，只在 Shell tool 底层加一层执行器抽象。

```python
# tools/sandbox/__init__.py
class SandboxExecutor(Protocol):
    async def exec(self, cmd: str, *, cwd: Path, timeout: int = 120,
                   env: dict[str, str] | None = None) -> ExecResult: ...
    async def cleanup(self) -> None: ...

# tools/sandbox/local.py — 包装现有 subprocess 逻辑
# tools/sandbox/docker.py — docker run + docker exec
```

Config:
```toml
[sandbox]
policy = "none"              # "none" | "docker"
image = "python:3.12-slim"
network = false
```

### 2. LLM 多后端

不重构 `create_llm()`，只加一个 `"custom"` 类型。Kimi CLI 已经支持 openai/anthropic/google，
`custom` 覆盖所有 OpenAI 兼容端点（DeepSeek、Ollama、vLLM 等）。

```python
# llm.py create_llm() 中新增:
case "custom":
    return OpenAIChatProvider(
        base_url=provider.base_url,
        api_key=resolve_api_key(provider),
        model=model.model,
    )
```

Config:
```toml
[providers.deepseek]
type = "custom"
base_url = "https://api.deepseek.com/v1"
api_key = { env = "DEEPSEEK_API_KEY" }

[models.deepseek-r1]
provider = "deepseek"
model = "deepseek-reasoner"
max_context_size = 64000
```

### 3. Auth

保留现有 OAuth 流程不动，只在 `setup_platform()` 开头加一个选择：

```
How would you like to connect?
[1] Login with Kimi/Moonshot account (OAuth)   ← 现有流程
[2] Enter API Key                              ← 新增
```

选 [2] → 输入 provider/api_key/model → 写入 config.toml。

### 4. Session Memory

在现有 `Session` 上附加一个 `SessionMetadata`，不改 Session 的核心逻辑。

```python
class SessionMetadata(BaseModel):
    model_name: str = ""
    provider: str = ""
    total_tokens: int = 0
    total_turns: int = 0
    tags: list[str] = []
```

存储为 `metadata.json`，和 `context.jsonl` 同目录。

### 5. Plugins

在 toolset 初始化时扫描 `~/.kimi/plugins/` 和 `.kimi/plugins/`，
加载含 `register(toolset)` 函数的 Python 模块。

### 6. Brand

只改 `constant.py` 的 `NAME` 和 `prompt.py` 的 `PROMPT_SYMBOL`。
不做全局 rename。
