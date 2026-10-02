#!/usr/bin/env bash
# 带自动重试的git push —— 本机网络中间设备(198.18.0.x)在长连接下会切断 SSH，
# 表现为 "Connection closed by ... port 22" 或 "Broken pipe"。
# 策略：每次尝试用 3 分钟超时（控制在中间设备掐断阈值内），失败则重试。
# 由于 git 只传远端缺失的对象，重试是幂等的，不会传重复数据。
set -u
cd /e/111/ldn-al20

export GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519_github -o IdentitiesOnly=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o TCPKeepAlive=yes"
BRANCH="${1:-bootstrap}"
MAX="${2:-12}"
ATTEMPT=0

while [ "$ATTEMPT" -lt "$MAX" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    printf '\n===== 推送尝试 %d/%d =====\n' "$ATTEMPT" "$MAX"
    # 每次用独立短超时，避免单次卡死拖垮整个流程
    if timeout 200 git push origin "$BRANCH:refs/heads/main" 2>&1 | tail -4; then
        # push 成功时 git 返回 0；但管道会取 tail 的码，故显式再查一次远端
        if git ls-remote origin refs/heads/main 2>/dev/null | grep -q .; then
            LOCAL=$(git rev-parse "$BRANCH")
            REMOTE=$(git ls-remote origin refs/heads/main 2>/dev/null | awk '{print $1}')
            if [ "$LOCAL" = "$REMOTE" ]; then
                echo "===== 推送成功，本地与远端一致：$LOCAL ====="
                exit 0
            fi
            echo "远端尚未同步（local=$LOCAL remote=$REMOTE），继续重试"
        fi
    fi
    echo "--- 本次失败，等待后重试 ---"
    sleep 5
done

echo "===== 达到最大重试次数仍未完成 ====="
exit 1
