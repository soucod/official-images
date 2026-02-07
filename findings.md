# 调研发现

## 需求摘要
1. **Git 提交自动同步**：代码推送后自动触发镜像同步流水线
2. **Web 手动触发**：在 CNB 界面通过按钮触发，支持输入参数
   - 仓库名（必填）
   - 版本（默认 latest）
   - 架构（默认 amd64/x86）
   - 平台（默认 hub.docker.com）
3. **命令行同步**：在 CNB 在线 VSCode 中执行命令
   - 同步单个镜像
   - 同步指定文件中的镜像列表
   - 同步全部镜像

## 技术调研

### CNB Docker 制品库
- **登录命令**: `docker login docker.cnb.cool -u cnb -p ${CNB_TOKEN}`
- **路径规则**:
  - 同名制品: `docker.cnb.cool/${CNB_REPO_SLUG_LOWERCASE}`
  - 非同名制品: `docker.cnb.cool/${CNB_REPO_SLUG_LOWERCASE}/<IMAGE_NAME>`
- **环境变量**:
  - `CNB_DOCKER_REGISTRY`: CNB Docker 仓库地址
  - `CNB_REPO_SLUG_LOWERCASE`: 仓库路径（小写）

### CNB 手动触发机制
- **配置文件**: `.cnb/web_trigger.yml`
- **按钮配置**:
  - `name`: 按钮显示名称
  - `description`: 按钮描述
  - `event`: 触发的 CI 事件名称
  - `inputs`: 用户输入参数定义
- **输入类型**: input, textarea, select, switch, radio
- **输入属性**: name, description, placeholder, required, default
- **访问输入值**: 通过 `${xxx}` 环境变量语法

### 镜像同步工具选择
| 工具 | 优点 | 缺点 |
|------|------|------|
| docker pull/push | 简单直接 | 需要本地存储空间 |
| skopeo | 无需本地存储，支持镜像复制 | 需要额外安装 |
| crane | 轻量级，Google 出品 | 功能相对简单 |

**选择**: 推荐使用 skopeo，因为它可以直接在仓库间复制镜像，无需中间存储。

### 项目结构分析
```
official-images/
├── library/           # 141 个 Docker Official Images 定义
├── test/              # 测试脚本
├── .github/workflows/ # 现有 GitHub Actions 工作流
└── (无 .cnb.yml)      # 需要创建
```

## 资源链接
- [CNB Docker 制品库文档](https://docs.cnb.cool/zh/artifact/docker.html)
- [CNB 手动触发文档](https://cnb.cool) - web_trigger 机制
- [skopeo 项目](https://github.com/containers/skopeo)

## 视觉/浏览器发现
- CNB 平台支持通过自定义按钮在仓库页面触发流水线
- 输入参数会作为环境变量传递给流水线脚本

---
*每两次查看/浏览/搜索操作后更新此文件*
