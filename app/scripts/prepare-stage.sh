#!/bin/bash
# app/scripts/prepare-stage.sh — 组装打包内嵌资源到 app/stage/wattson/。
# 不用 electron-builder extraResources 的 filter：它硬性排除 node_modules，
# 而 server 打包态运行依赖 node_modules 里的 tsx，必须原样带上（不进 asar）。
#
# 体积口径：只装「运行时」依赖——server 只需 tsx 转译链（esbuild 等），
# codeburn 只装 dependencies（CLI 的 react/ink、解析器的 undici/zod 等）；
# typescript/vitest/playwright/tsup 等构建与测试工具一律不进包。
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
STAGE="$APP/stage/wattson"
rm -rf "$STAGE"
mkdir -p "$STAGE/server" "$STAGE/codeburn"

# server：源码 + tsconfig（tsx 的 @codeburn/* 路径映射）+ 运行时依赖
# 依赖用仓库的 package.json + package-lock.json 以 npm ci 安装：不再手工重建
# "tsx": "^4" 之类的浮动清单（同一源码版本可能打出不同依赖组合）；
# tsx 已是 server 的 dependencies，--omit=dev 即可带上并锁定版本
rsync -a "$ROOT/server/src" "$STAGE/server/"
cp "$ROOT/server/tsconfig.json" "$ROOT/server/package.json" "$ROOT/server/package-lock.json" "$STAGE/server/"
(cd "$STAGE/server" && npm ci --omit=dev --no-audit --no-fund --loglevel=error)

# codeburn：源码（tsx 经 paths 直接吃 TS 源）+ dist（CLI）+ 运行时 dependencies
# 同样走 lockfile（npm ci），构建/测试工具不进包
rsync -a "$ROOT/codeburn/src" "$ROOT/codeburn/dist" "$STAGE/codeburn/"
cp "$ROOT/codeburn/package.json" "$ROOT/codeburn/package-lock.json" "$STAGE/codeburn/"
(cd "$STAGE/codeburn" && npm ci --omit=dev --no-audit --no-fund --loglevel=error)

# web 看板产物 + 镜像脚本（客户端内置 30 分钟同步调度）
rsync -a "$ROOT/web/dist" "$STAGE/web/"
mkdir -p "$STAGE/sync"
cp "$ROOT/sync/mirror.sh" "$STAGE/sync/"

echo "stage ready: $STAGE"
du -sh "$STAGE/server/node_modules" "$STAGE/codeburn/node_modules" "$STAGE" | awk '{print "size: "$0}'
