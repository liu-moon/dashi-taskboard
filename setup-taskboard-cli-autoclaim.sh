#!/bin/zsh
# 把 ros2-learning 的 Taskboard 自动认领从 Codex 桌面 Scheduled
# 换成本机 launchd + Codex CLI。第一次 taskctl 即可访问本机回环服务。
#
# 用法：
#   ./setup-taskboard-cli-autoclaim.sh           安装并启动每 5 分钟定时认领
#   ./setup-taskboard-cli-autoclaim.sh status    查看状态
#   ./setup-taskboard-cli-autoclaim.sh once      只跑一轮（不改定时）
#   ./setup-taskboard-cli-autoclaim.sh uninstall 停止并卸载

set -euo pipefail

PROJECT_ID="2384c20f-5731-438b-b8ac-795e062859c0"
PROJECT_DIR="/Users/liuiu/Documents/ChatGPT/ros2-learning"
AUTOMATION_DIR="$HOME/.codex/automations/taskboard-${PROJECT_ID}"
CLI_DIR="$AUTOMATION_DIR/cli"
PROMPT_FILE="$CLI_DIR/prompt.txt"
RUN_FILE="$CLI_DIR/run.sh"
LOCK_FILE="$CLI_DIR/run.lock"
LOG_FILE="$CLI_DIR/logs/run.log"
RUNTIME_FILE="$HOME/Library/Application Support/Codex Taskboard/launcher-runtime.json"
TASKCTL_NODE="/Applications/Codex Taskboard.app/Contents/MacOS/node"
TASKCTL_JS="/Applications/Codex Taskboard.app/Contents/Resources/app/cli/taskctl.mjs"
CODEX_BIN="${CODEX_BIN:-$HOME/.local/bin/codex}"
PLIST_LABEL="com.liuiu.taskboard-cli-autoclaim"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
INTERVAL_SECONDS=300

taskctl() {
  "$TASKCTL_NODE" "$TASKCTL_JS" --runtime-file "$RUNTIME_FILE" "$@"
}

need() {
  if [[ ! -x $1 ]]; then
    print -u2 "找不到可执行文件：$1"
    exit 1
  fi
}

extract_prompt() {
  python3 - "$AUTOMATION_DIR/automation.toml" "$PROMPT_FILE" <<'PY'
from pathlib import Path
import sys
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text(encoding="utf-8")
start = text.find('prompt = "')
end = text.find('"\nstatus =')
if start < 0 or end < 0:
    raise SystemExit("automation.toml 里没有找到 prompt")
raw = text[start + len('prompt = "'):end]
prompt = raw.replace("\\n", "\n").replace('\\"', '"')
dest.write_text(prompt + ("\n" if not prompt.endswith("\n") else ""), encoding="utf-8")
print(dest)
PY
}

write_runner() {
  cat > "$RUN_FILE" <<EOF
#!/bin/zsh
set -euo pipefail

PROJECT_ID="$PROJECT_ID"
PROJECT_DIR="$PROJECT_DIR"
CLI_DIR="$CLI_DIR"
PROMPT_FILE="$PROMPT_FILE"
LOCK_FILE="$LOCK_FILE"
LOG_FILE="$LOG_FILE"
RUNTIME_FILE="$RUNTIME_FILE"
TASKCTL_NODE="$TASKCTL_NODE"
TASKCTL_JS="$TASKCTL_JS"
CODEX_BIN="$CODEX_BIN"

exec >> "\$LOG_FILE" 2>&1
print -- "----- \$(date '+%Y-%m-%d %H:%M:%S %Z') -----"

if [[ -f \$LOCK_FILE ]]; then
  old_pid=\$(cat "\$LOCK_FILE" 2>/dev/null || true)
  if [[ -n \$old_pid ]] && kill -0 "\$old_pid" 2>/dev/null; then
    print "上一轮还在跑 pid=\$old_pid，跳过"
    exit 0
  fi
fi
print \$\$ > "\$LOCK_FILE"
trap 'rm -f "\$LOCK_FILE"' EXIT

if [[ ! -f \$RUNTIME_FILE ]]; then
  print "Taskboard runtime 不存在，跳过：\$RUNTIME_FILE"
  exit 0
fi
if ! "\$TASKCTL_NODE" "\$TASKCTL_JS" --runtime-file "\$RUNTIME_FILE" \\
    issue list --project "\$PROJECT_ID" --status todo --json >/tmp/taskboard-cli-todos.json
then
  print "taskctl issue list 失败，跳过本轮"
  exit 0
fi

python3 - <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path("/tmp/taskboard-cli-todos.json").read_text())
tasks = data.get("tasks") or []
print(f"todo 数量：{len(tasks)}")
if not tasks:
    sys.exit(2)
for task in tasks:
    print(f"- {task.get('identifier')} {task.get('title')} status={task.get('status')}")
PY
  local todo_status=\$?
  if [[ \$todo_status -eq 2 ]]; then
    print "没有 todo，本轮不启动 Codex"
    exit 0
  fi
  if [[ \$todo_status -ne 0 ]]; then
    print "解析 todo 列表失败"
    exit 0
  fi

  exec "\$CODEX_BIN" exec \\
    --cd "\$PROJECT_DIR" \\
    --skip-git-repo-check \\
    --sandbox workspace-write \\
    --add-dir "\$CLI_DIR" \\
    --add-dir "$AUTOMATION_DIR" \\
    -c 'sandbox_workspace_write.network_access=true' \\
    -c 'approval_policy="never"' \\
    -m gpt-5.5 \\
    -c 'model_reasoning_effort="low"' \\
    "\$(cat "\$PROMPT_FILE")"
EOF
  chmod +x "$RUN_FILE"
}

write_plist() {
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>${RUN_FILE}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${PROJECT_DIR}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL_SECONDS}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF
}

unload_job() {
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
}

load_job() {
  unload_job
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
}

show_status() {
  print "plist: $PLIST_PATH"
  print "runner: $RUN_FILE"
  print "log: $LOG_FILE"
  if [[ -f $AUTOMATION_DIR/automation.toml ]]; then
    python3 - "$AUTOMATION_DIR/automation.toml" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
for line in text.splitlines():
    if line.startswith("status = "):
        print("桌面自动化：", line.split("=", 1)[1].strip().strip('"'))
        break
PY
  fi
  launchctl print "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null | sed -n '1,16p' || print "launchd 未加载"
}

install() {
  need "$CODEX_BIN"
  need "$TASKCTL_NODE"
  if [[ ! -f $TASKCTL_JS ]]; then
    print -u2 "找不到 taskctl：$TASKCTL_JS"
    exit 1
  fi
  if [[ ! -f $RUNTIME_FILE ]]; then
    print -u2 "找不到 Taskboard runtime。先打开 Codex Taskboard App。"
    exit 1
  fi
  if [[ ! -f $AUTOMATION_DIR/automation.toml ]]; then
    print -u2 "找不到桌面自动化配置：$AUTOMATION_DIR/automation.toml"
    exit 1
  fi

  mkdir -p "$CLI_DIR/logs" "$(dirname "$PLIST_PATH")"
  extract_prompt
  write_runner
  write_plist
  load_job

  if grep -q '^status = "ACTIVE"' "$AUTOMATION_DIR/automation.toml"; then
    print "注意：Codex 桌面那条「Taskboard 自动认领」仍是 ACTIVE。"
    print "请在 Codex Scheduled 里暂停它，避免两边同时认领。"
  fi

  print
  print "已安装 CLI 定时认领，每 ${INTERVAL_SECONDS} 秒检查一次。"
  print "立刻试跑一轮： $0 once"
  print "查看状态：     $0 status"
  print "卸载：         $0 uninstall"
  print "日志：         $LOG_FILE"
}

run_once() {
  need "$CODEX_BIN"
  need "$TASKCTL_NODE"
  if [[ ! -x $RUN_FILE ]]; then
    print -u2 "还没安装。先运行：$0"
    exit 1
  fi
  /bin/zsh "$RUN_FILE"
}

uninstall() {
  unload_job
  rm -f "$PLIST_PATH"
  print "已停止 launchd 任务，并删除 $PLIST_PATH"
  print "提示词和 runner 仍留在 $CLI_DIR ，需要可手动删。"
}

case "${1:-install}" in
  install) install ;;
  status) show_status ;;
  once) run_once ;;
  uninstall) uninstall ;;
  *)
    print -u2 "用法：$0 [install|status|once|uninstall]"
    exit 1
    ;;
esac
