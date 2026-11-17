#!/bin/zsh
# 生成可发布到 GitHub 的公开副本，并在导出后做基础敏感信息扫描。
#
# 用法：scripts/export-public.sh <目标目录>
#   目标目录必须不存在或为空。导出不含 git 历史，请在目标目录里 `git init` 新建仓库。
#
# 仅导出公开文件与源码/资源/测试/脚本中的允许类型。
# 构建产物、内部文档、AI 助手说明、日志和私有关键字清单不会导出。
# 检查：若项目根目录存在 .private-patterns（每行一个关键字，# 开头为注释，
#       不区分大小写），导出结果中命中任意一条即报错退出。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  print -u2 "用法：$0 <目标目录>"
  exit 2
fi
if [[ -e "$TARGET" && -n "$(/bin/ls -A "$TARGET" 2>/dev/null)" ]]; then
  print -u2 "目标目录不为空：$TARGET"
  exit 2
fi
/bin/mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
case "$TARGET" in
  "$ROOT_DIR"|"$ROOT_DIR"/*)
    print -u2 "目标目录不能位于项目目录内：$TARGET"
    exit 2
    ;;
esac

# 仅列出明确允许的文件；新加入的配置、日志或隐藏文件不会自动进入公开副本。
file_list="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$file_list"' EXIT
root_files=(.gitignore LICENSE Package.swift README.md recover-network.command)
for rel in "${root_files[@]}"; do
  if [[ ! -f "$ROOT_DIR/$rel" || -L "$ROOT_DIR/$rel" ]]; then
    print -u2 "缺少公开文件或文件为符号链接：$rel"
    exit 1
  fi
  /usr/bin/printf '%s\0' "$rel" >> "$file_list"
done

for group in Resources Sources Tests scripts; do
  while IFS= read -r -d '' path; do
    rel="${path#$ROOT_DIR/}"
    case "$rel" in
      Resources/*.plist|Sources/*.swift|Sources/*.c|Sources/*.h|Tests/*.swift|Tests/*.cidrs|scripts/*.sh)
        /usr/bin/printf '%s\0' "$rel" >> "$file_list"
        ;;
    esac
  done < <(/usr/bin/find "$ROOT_DIR/$group" -type f -print0)
done

while IFS= read -r -d '' rel; do
  /bin/mkdir -p "$TARGET/${rel:h}"
  /bin/cp -p "$ROOT_DIR/$rel" "$TARGET/$rel"
done < "$file_list"

found=0

# 基础检查：本机用户路径、Apple 私密转发邮箱、邮箱地址和高置信凭据形态。
if /usr/bin/grep -rnI -E \
  -e '/Users/[A-Za-z0-9._-]+/|privaterelay\.appleid\.com' \
  -e '[[:alnum:]_.+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' \
  -e '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|AKIA[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{20,}|tskey-[A-Za-z0-9_-]{12,}|sk-[A-Za-z0-9_-]{20,}' \
  "$TARGET"; then
  found=1
fi

# 用户自定义的私有关键字。
PATTERNS="$ROOT_DIR/.private-patterns"
if [[ -f "$PATTERNS" ]]; then
  tmp_patterns="$(/usr/bin/mktemp)"
  /usr/bin/grep -v -E '^[[:space:]]*(#|$)' "$PATTERNS" > "$tmp_patterns" || true
  if [[ -s "$tmp_patterns" ]] && /usr/bin/grep -rnI -i -F -f "$tmp_patterns" "$TARGET"; then
    found=1
  fi
  /bin/rm -f "$tmp_patterns"
else
  print "提示：未找到 .private-patterns，只做了基础模式扫描。"
fi

if [[ "$found" -ne 0 ]]; then
  print -u2 ""
  print -u2 "导出结果中仍含上面列出的私有信息，请先处理后再发布。导出目录：$TARGET"
  exit 1
fi

print "已导出公开副本：$TARGET"
print "基础模式扫描未命中；发布前仍需人工复查。下一步：cd \"$TARGET\" && git init && git add . && git commit -m 'Initial public release'"
