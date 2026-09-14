# newapi 一键部署 / 管理（轻量服务器 / SQLite 版）

针对 **1G 内存轻量服务器 + 国内网络** 优化的 New API 部署与管理方案，带交互菜单。

- 数据库用 **SQLite**（单文件，最省内存，1G 服务器无压力，重启不丢数据）
- 自动检测并安装 Docker（已装则跳过，用国内镜像源安装）
- 自动配置 Docker 国内镜像加速
- 自动生成随机 `SESSION_SECRET` / `CRYPTO_SECRET`
- 镜像源按网络区域选择 + 拉取超时兜底：安装时问「国内/境外」，境外只直连 Docker Hub（不试慢国内源）；每次 `docker pull` 超 120s 自动跳下一个源，慢源不会卡死

## 一行部署（执行后进入菜单）

在服务器上（root）执行：

```bash
curl -fsSL https://raw.githubusercontent.com/USER/newapi-1click-deploy/main/deploy.sh | bash
```

> 把 `USER` 替换成你的 GitHub 用户名。脚本跑起来会显示菜单，输入 `1` 即开始安装。

## 菜单说明

| 编号 | 功能 | 说明 |
|------|------|------|
| 1 | 安装 | 检测/安装 Docker + 拉起 new-api（写入 docker-compose.yml） |
| 2 | 启动 | 启动已部署的服务 |
| 3 | 停止 | 停止服务，保留数据 |
| 4 | 重启 | 重启服务 |
| 5 | 卸载 | 停止并移除容器与镜像（二次确认；**会再问是否连数据目录一起删**） |
| 6 | 更新 | 拉取最新镜像并重启 |
| 7 | 状态 | 查看容器运行状态 |
| 8 | 日志 | 查看最近 100 行日志 |
| 9 | 备份 | 打包 `./data` 与 `./logs` 为 tar.gz |
| 10 | 访问地址 | 打印当前对外访问 URL |
| 11 | 修改端口 | 改宿主机映射端口（校验合法性/占用，自动改 compose 并重建） |
| 0 | 退出 | — |

## 单行命令（免交互）

不想进菜单，可直接带动作参数：

```bash
bash deploy.sh install     # 安装
bash deploy.sh start       # 启动
bash deploy.sh stop        # 停止
bash deploy.sh restart     # 重启
bash deploy.sh uninstall   # 卸载
bash deploy.sh update      # 更新
bash deploy.sh status      # 状态
bash deploy.sh logs        # 日志
bash deploy.sh backup      # 备份
bash deploy.sh address     # 访问地址
bash deploy.sh port        # 修改端口
```

## 可选环境变量

```bash
NEWAPI_DIR=/opt/new-api NEWAPI_PORT=3000 NEWAPI_REGION=cn bash deploy.sh install
```

- `NEWAPI_REGION`：`cn`（国内源）或 `global`（境外直连 Docker Hub，默认）。非交互安装时用于跳过区域提问。

## 已有 Docker 的用户

可直接用仓库里的 `docker-compose.yml`：

```bash
docker compose up -d
```

## 使用

- 访问 `http://<服务器IP>:3000`，首次打开进入初始化页面，设置管理员账号密码即可。
- 实时日志：`cd /opt/new-api && docker compose logs -f`
- 停止：`cd /opt/new-api && docker compose down`

## 数据备份

数据在 `./data` 目录（SQLite 库 + 配置）。菜单选 `9` 一键打包，或：

```bash
tar -czf backup.tar.gz -C /opt/new-api data logs
```

## 注意事项

- 1G 内存下**不要**用 PostgreSQL/MySQL 方案，SQLite 是最稳的。
- 镜像拉取：安装时选网络区域决定候选源，**境内**=阿里云→github.ai.plus→Docker Hub，**境外**=Docker Hub→github.ai.plus（直连最快，不试慢国内源）。每次 `docker pull` 带 120s 超时，慢到超时会自动跳下一个源，不会卡死。非交互（curl|bash）默认按境外策略；也可用 `NEWAPI_REGION=cn bash deploy.sh install` 强制国内源。
- 仓库里的 `docker-compose.yml`（给已有 Docker 用户直用）默认 `calciumion/new-api:latest`（Docker Hub）；国内拉不动可改成阿里云镜像（文件内有注释）。
- 本方案为单机部署；多机/集群需固定 `SESSION_SECRET` 与 `CRYPTO_SECRET` 并共用数据库。
- 卸载默认只移除容器与镜像，数据目录 `/opt/new-api/data` 默认保留；选「5 卸载」时会再问一次是否连数据一起删。
