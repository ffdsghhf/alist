# Dockerfile for Custom AList Multi-Arch Build (Musl based, Final Image included)

# --- Stage 1: Builder ---
FROM golang:1.22-alpine AS builder

LABEL stage=go-builder
WORKDIR /app/

# 安装构建依赖 (确保 C 编译器和 musl-dev 可用)
RUN apk add --no-cache git build-base ca-certificates

COPY go.mod go.sum ./
RUN go mod download
COPY . .

# --- !!! 修改这里：直接执行静态编译 !!! ---
# 不再调用 build.sh release docker
# 使用 CGO_ENABLED=1, 指定静态链接 Musl
# 将编译结果直接输出到 /alist (方便后面复制)
RUN export CGO_ENABLED=1 && \
    go build -ldflags="-w -s -linkmode external -extldflags '-static'" -tags=jsoniter -o /alist .
# --- !!! 修改结束 !!! ---

# --- Stage 2: Final Image ---
FROM alpine:latest # 使用稳定版 Alpine 可能比 edge 更可靠

ARG INSTALL_FFMPEG=false
ARG INSTALL_ARIA2=false
LABEL MAINTAINER="i@nn.ci" # 可以改成你自己的信息

WORKDIR /opt/alist/

# 安装运行时依赖 + 可选组件
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache bash ca-certificates su-exec tzdata; \
    [ "$INSTALL_FFMPEG" = "true" ] && apk add --no-cache ffmpeg; \
    [ "$INSTALL_ARIA2" = "true" ] && apk add --no-cache curl aria2 && \
        # --- Aria2 配置部分 (保持不变) ---
        mkdir -p /opt/aria2/.aria2 && \
        wget https://github.com/P3TERX/aria2.conf/archive/refs/heads/master.tar.gz -O /tmp/aria-conf.tar.gz && \
        tar -zxvf /tmp/aria-conf.tar.gz -C /opt/aria2/.aria2 --strip-components=1 && rm -f /tmp/aria-conf.tar.gz && \
        sed -i 's|rpc-secret|#rpc-secret|g' /opt/aria2/.aria2/aria2.conf && \
        sed -i 's|/root/.aria2|/opt/aria2/.aria2|g' /opt/aria2/.aria2/aria2.conf && \
        sed -i 's|/root/.aria2|/opt/aria2/.aria2|g' /opt/aria2/.aria2/script.conf && \
        sed -i 's|/root|/opt/aria2|g' /opt/aria2/.aria2/aria2.conf && \
        sed -i 's|/root|/opt/aria2|g' /opt/aria2/.aria2/script.conf && \
        touch /opt/aria2/.aria2/aria2.session && \
        (cd /opt/aria2/.aria2 && bash tracker.sh || echo "Tracker update failed, continuing...") ; \ # 增加错误处理
    # --- 清理缓存 ---
    rm -rf /var/cache/apk/*

# --- !!! 修改这里：从 /alist 复制 !!! ---
# 从 builder 阶段复制编译好的静态 alist 文件到当前目录 (.)
COPY --chmod=755 --from=builder /alist ./alist
# --- !!! 修改结束 !!! ---

# 复制入口点脚本 (如果需要的话，确保 entrypoint.sh 在你的源码根目录)
# COPY --chmod=755 entrypoint.sh /entrypoint.sh
# 如果不需要自定义 entrypoint，可以直接使用 alist 命令

# (可选) 运行 version 命令验证 (如果需要 entrypoint.sh)
# RUN /entrypoint.sh version

# 环境变量 (保持不变)
ENV PUID=0 PGID=0 UMASK=022 RUN_ARIA2=${INSTALL_ARIA2}

# 数据卷 (修改为当前工作目录下的 data)
VOLUME ./data/
EXPOSE 5244 5245

# --- !!! 修改这里：简化启动命令 !!! ---
# 如果没有复杂的 entrypoint 逻辑，可以直接启动 alist
# 确保数据目录是相对路径 ./data 或绝对路径 /opt/alist/data
CMD ["./alist", "server", "--data", "./data"]
# 或者如果需要 entrypoint.sh:
# CMD [ "/entrypoint.sh" ]
# --- !!! 修改结束 !!! ---
