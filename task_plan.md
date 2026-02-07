# Task Plan: CNB Docker 镜像自动同步方案

## 目标
实现 CNB 平台 Docker 镜像的多种同步方式：Git 提交自动触发、Web 界面手动触发（带参数）、以及 VSCode 终端命令行同步。

## 当前阶段
Phase 1

## 阶段计划

### Phase 1: 需求分析与技术调研
- [x] 理解用户需求和使用场景
- [x] 阅读 CNB Docker 制品库文档
- [x] 调研 CNB 手动触发流水线机制
- [x] 分析现有项目结构
- **状态:** 已完成

### Phase 2: 方案设计与用户确认
- [ ] 制定详细实施方案
- [ ] 创建 implementation_plan.md
- [ ] 提交用户审核
- **状态:** 进行中

### Phase 3: 核心脚本开发
- [ ] 创建通用镜像同步脚本 `sync-image.sh`
- [ ] 创建镜像清单文件 `docker-images.txt`
- [ ] 创建批量同步脚本 `sync-all-images.sh`
- **状态:** 待进行

### Phase 4: CNB 配置文件
- [ ] 创建 `.cnb.yml` 流水线配置
- [ ] 创建 `.cnb/web_trigger.yml` 手动触发配置
- **状态:** 待进行

### Phase 5: 测试与验证
- [ ] 在 CNB 在线 IDE 中测试命令行同步
- [ ] 测试 Web 界面手动触发
- [ ] 测试 Git 推送自动触发
- **状态:** 待进行

## 关键问题
1. CNB 环境变量：`CNB_DOCKER_REGISTRY`, `CNB_REPO_SLUG_LOWERCASE` 如何使用？
2. 如何处理多架构镜像（amd64, arm64）？
3. 是否需要支持多个源平台（Docker Hub, GHCR 等）？

## 决策记录
| 决策 | 理由 |
|------|------|
| 使用 `.cnb/web_trigger.yml` 实现手动触发 | CNB 官方推荐方式，支持自定义按钮和输入参数 |
| 镜像路径格式：`docker.cnb.cool/${CNB_REPO_SLUG_LOWERCASE}/<IMAGE_NAME>:<TAG>` | 非同名制品规范，便于组织管理 |
| 使用 skopeo 代替 docker pull/push | 无需本地存储，支持跨仓库镜像复制，效率更高 |

## 遇到的问题
| 问题 | 解决方案 |
|------|----------|
| (暂无) | |

## 备注
- 项目当前没有 `.cnb.yml` 配置文件，需要新建
- 参考脚本使用 bashbrew 工具，适用于 Docker Official Images 构建
- 本方案将支持任意 Docker 镜像源同步，不限于 Official Images
