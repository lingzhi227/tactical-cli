# Tactical CLI 实施计划

> 基于 [architecture.md](./architecture.md)
> 策略：kimi-cli 原样保留，增量扩展

---

## Step 1: Sandbox 执行环境

### 1.1 新建 `src/kimi_cli/tools/sandbox/__init__.py`

```python
from __future__ import annotations
from typing import Protocol
from pathlib import Path
from pydantic import BaseModel


class ExecResult(BaseModel):
    exit_code: int
    stdout: str
    stderr: str
    timed_out: bool = False


class SandboxExecutor(Protocol):
    async def exec(self, cmd: str, *, cwd: Path, timeout: int = 120,
                   env: dict[str, str] | None = None) -> ExecResult: ...
    async def cleanup(self) -> None: ...
```

### 1.2 新建 `src/kimi_cli/tools/sandbox/local.py`

```python
"""直接本地执行，包装现有 Shell tool 的 subprocess 逻辑。"""
import asyncio
from pathlib import Path
from .import ExecResult


class LocalExecutor:
    async def exec(self, cmd, *, cwd, timeout=120, env=None):
        try:
            proc = await asyncio.create_subprocess_shell(
                cmd, cwd=str(cwd), env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return ExecResult(
                exit_code=proc.returncode or 0,
                stdout=stdout.decode(errors="replace"),
                stderr=stderr.decode(errors="replace"),
            )
        except asyncio.TimeoutError:
            proc.kill()
            return ExecResult(exit_code=-1, stdout="", stderr="Timed out", timed_out=True)

    async def cleanup(self):
        pass
```

### 1.3 新建 `src/kimi_cli/tools/sandbox/docker.py`

```python
"""Docker 容器沙箱。通过 docker CLI 执行，无额外 Python 依赖。"""
import asyncio
import uuid
from pathlib import Path
from . import ExecResult


class DockerSandboxExecutor:
    def __init__(self, image: str = "python:3.12-slim",
                 work_dir: Path = Path.cwd(), network: bool = False):
        self._image = image
        self._work_dir = work_dir
        self._network = network
        self._container_id: str | None = None
        self._name = f"kimi-sandbox-{uuid.uuid4().hex[:8]}"

    async def _ensure(self):
        if self._container_id:
            return
        net = "bridge" if self._network else "none"
        proc = await asyncio.create_subprocess_exec(
            "docker", "run", "-d", "--name", self._name,
            "--network", net,
            "-v", f"{self._work_dir}:/workspace", "-w", "/workspace",
            self._image, "sleep", "infinity",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        out, err = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(f"Docker sandbox failed: {err.decode()}")
        self._container_id = out.decode().strip()

    async def exec(self, cmd, *, cwd, timeout=120, env=None):
        await self._ensure()
        args = ["docker", "exec"]
        if env:
            for k, v in env.items():
                args.extend(["-e", f"{k}={v}"])
        try:
            rel = Path(cwd).relative_to(self._work_dir)
        except ValueError:
            rel = Path(".")
        args.extend(["-w", f"/workspace/{rel}", self._name, "sh", "-c", cmd])
        try:
            proc = await asyncio.create_subprocess_exec(
                *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return ExecResult(
                exit_code=proc.returncode or 0,
                stdout=out.decode(errors="replace"),
                stderr=err.decode(errors="replace"),
            )
        except asyncio.TimeoutError:
            return ExecResult(exit_code=-1, stdout="", stderr="Timed out", timed_out=True)

    async def cleanup(self):
        if self._container_id:
            await asyncio.create_subprocess_exec(
                "docker", "rm", "-f", self._name,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            self._container_id = None
```

### 1.4 改 `src/kimi_cli/config.py` — 加 sandbox 配置

在 `Config` 类中加:

```python
class SandboxConfig(BaseModel):
    policy: Literal["none", "docker"] = "none"
    image: str = "python:3.12-slim"
    network: bool = False

class Config(BaseModel):
    # ... 现有字段 ...
    sandbox: SandboxConfig = SandboxConfig()
```

### 1.5 改 `src/kimi_cli/soul/agent.py` — Runtime 加 sandbox

```diff
  @dataclass
  class Runtime:
      config: Config
      oauth: OAuthManager
      llm: LLM | None
      session: Session
+     sandbox: SandboxExecutor  # from kimi_cli.tools.sandbox
      # ... 其余字段不动
```

### 1.6 改 `src/kimi_cli/tools/shell/__init__.py` — 通过 executor 执行

找到 Shell tool 中直接调用 `subprocess` 的地方，改为:

```python
from kimi_cli.tools.sandbox import SandboxExecutor

# 在 execute() 方法中:
sandbox: SandboxExecutor = self._deps[SandboxExecutor]  # 通过依赖注入获取
result = await sandbox.exec(command, cwd=self._cwd, timeout=timeout, env=self._env)
```

保留原有的 Approval 流程不动——sandbox 只替换执行层，不影响审批。

### 1.7 改 `src/kimi_cli/app.py` — 创建 executor 并传入 Runtime

```python
from kimi_cli.tools.sandbox.local import LocalExecutor
from kimi_cli.tools.sandbox.docker import DockerSandboxExecutor

def _create_sandbox(config: Config, work_dir: Path) -> SandboxExecutor:
    if config.sandbox.policy == "docker":
        return DockerSandboxExecutor(
            image=config.sandbox.image, work_dir=work_dir,
            network=config.sandbox.network,
        )
    return LocalExecutor()

# 在构建 Runtime 时:
runtime = Runtime(
    ...,
    sandbox=_create_sandbox(config, work_dir),
)

# 在退出时:
await runtime.sandbox.cleanup()
```

### 验证

```bash
# 无沙箱（默认行为不变）
kimi "run ls"

# Docker 沙箱
# config.toml 加 [sandbox]\npolicy = "docker"
kimi "run whoami"   # 应返回 root
```

---

## Step 2: LLM 加 custom provider

### 2.1 改 `src/kimi_cli/llm.py` — create_llm() 加一个分支

在 `create_llm()` 的 match/if 链中，加:

```python
case "custom":
    # 任何 OpenAI 兼容端点 (DeepSeek, Ollama, vLLM, LMStudio...)
    chat_provider = create_openai_legacy_provider(
        base_url=provider.base_url,
        api_key=resolve_api_key(provider),
        model=model.model,
    )
```

`create_openai_legacy_provider` 复用已有的 `openai_legacy` 逻辑。
实际上 `custom` 就是 `openai_legacy` 的别名，只是语义更清晰。

### 2.2 改 `src/kimi_cli/config.py` — ProviderType 加 "custom"

如果 `ProviderType` 是 Literal：

```diff
- ProviderType = Literal["kimi", "openai_legacy", "openai_responses", "anthropic", "google_genai", ...]
+ ProviderType = Literal["kimi", "openai_legacy", "openai_responses", "anthropic", "google_genai", ..., "custom"]
```

### 验证

```toml
# config.toml
[providers.deepseek]
type = "custom"
base_url = "https://api.deepseek.com/v1"
api_key = { env = "DEEPSEEK_API_KEY" }

[models.ds]
provider = "deepseek"
model = "deepseek-chat"
max_context_size = 64000

default_model = "ds"
```

```bash
kimi --model ds "hello"
```

---

## Step 3: Auth 加 API Key 路径

### 3.1 改 `src/kimi_cli/ui/shell/setup.py`

在 `setup_platform()` 最前面加选择:

```python
async def setup_platform(config: Config) -> Config:
    console.print("\nHow would you like to connect?\n")
    console.print("  [1] Login with Moonshot/Kimi account")
    console.print("  [2] Enter API Key directly\n")

    choice = Prompt.ask("Choose", choices=["1", "2"], default="1")
    if choice == "1":
        return await _setup_oauth(config)   # 现有逻辑移到这个函数
    return await _setup_api_key(config)


async def _setup_api_key(config: Config) -> Config:
    providers = [
        ("openai", "openai_legacy", "OpenAI"),
        ("anthropic", "anthropic", "Anthropic"),
        ("deepseek", "custom", "DeepSeek"),
        ("custom", "custom", "Custom endpoint"),
    ]
    for i, (_, _, label) in enumerate(providers, 1):
        console.print(f"  [{i}] {label}")

    idx = int(Prompt.ask("Provider", choices=[str(i) for i in range(1, len(providers)+1)])) - 1
    key, ptype, _ = providers[idx]

    base_url = None
    if key == "custom":
        base_url = Prompt.ask("Base URL")
    api_key = Prompt.ask("API Key", password=True)
    model = Prompt.ask("Model name")

    config.providers[key] = LLMProvider(type=ptype, base_url=base_url, api_key=SecretStr(api_key))
    config.models["default"] = LLMModel(provider=key, model=model, max_context_size=128000)
    config.default_model = "default"
    save_config(config)
    return config
```

不动现有 OAuth 代码，只是在前面包一层选择。

---

## Step 4: Session Metadata

### 4.1 改 `src/kimi_cli/session.py` — 加 SessionMetadata

```python
class SessionMetadata(BaseModel):
    model_name: str = ""
    provider: str = ""
    total_tokens: int = 0
    total_turns: int = 0
    tags: list[str] = []

    @classmethod
    def load(cls, path: Path) -> SessionMetadata:
        if path.exists():
            return cls.model_validate_json(path.read_text())
        return cls()

    def save(self, path: Path) -> None:
        path.write_text(self.model_dump_json(indent=2))
```

在 `Session` 类加:

```diff
  class Session:
      # ... 现有字段 ...
+     metadata: SessionMetadata
+     metadata_file: Path
+
+     def save_metadata(self):
+         self.metadata.save(self.metadata_file)
```

在 `Session.create()` 中初始化 `metadata_file` 和 `metadata`。

### 4.2 改 `src/kimi_cli/soul/kimisoul.py` — turn 结束时更新

在每次 turn 完成的位置加:

```python
session.metadata.total_turns += 1
session.metadata.total_tokens += token_usage.total_tokens
session.metadata.model_name = self._llm.model_config.model
session.save_metadata()
```

---

## Step 5: 外部 Tool Plugin

### 5.1 新建 `src/kimi_cli/plugins/__init__.py`

```python
import importlib.util
from pathlib import Path
from kimi_cli.utils.logging import logger


def load_plugins(plugin_dirs: list[Path], toolset) -> int:
    count = 0
    for d in plugin_dirs:
        if not d.is_dir():
            continue
        for f in sorted(d.iterdir()):
            mod = None
            if f.suffix == ".py" and f.is_file():
                mod = _load(f)
            elif f.is_dir() and (f / "__init__.py").exists():
                mod = _load(f / "__init__.py")
            if mod and hasattr(mod, "register"):
                try:
                    mod.register(toolset)
                    count += 1
                except Exception as e:
                    logger.warning("Plugin {f} failed: {e}", f=f.name, e=e)
    return count


def _load(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if not spec or not spec.loader:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
```

### 5.2 改 `src/kimi_cli/soul/toolset.py` — 加载插件

在 toolset 初始化最后加:

```python
from kimi_cli.plugins import load_plugins

load_plugins([
    Path.home() / ".kimi" / "plugins",
    Path.cwd() / ".kimi" / "plugins",
], toolset)
```

---

## Step 6: Brand 定制

### 6.1 改 `src/kimi_cli/constant.py`

```python
NAME = "Your Brand CLI"
USER_AGENT = f"YourBrand/{VERSION}"
```

### 6.2 改 `src/kimi_cli/ui/shell/prompt.py`

```python
PROMPT_SYMBOL = "⚡"
PROMPT_SYMBOL_THINKING = "🧠"
```

### 6.3 改 welcome 信息

`src/kimi_cli/ui/shell/__init__.py` 中修改 welcome 显示文本。

---

## 总结

| Step | 新文件 | 改动文件 | 新增代码量 |
|------|--------|---------|-----------|
| 1. Sandbox | 3 | 4 | ~120 行 |
| 2. LLM custom | 0 | 2 | ~15 行 |
| 3. Auth API key | 0 | 1 | ~40 行 |
| 4. Session meta | 0 | 2 | ~25 行 |
| 5. Plugins | 1 | 1 | ~30 行 |
| 6. Brand | 0 | 3 | ~5 行 |
| **Total** | **4** | **13** | **~235 行** |

全部改动不影响 kimi-cli 的现有功能。`policy = "none"` 时行为完全等同原版。
