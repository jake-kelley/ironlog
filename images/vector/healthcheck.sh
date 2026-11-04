#!/bin/bash
# Exit 0 when Vector's API answers GET /health with 200. The API listens on
# 127.0.0.1:8686, so this runs inside the container (exec-style probe).
set -euo pipefail
exec 3<>/dev/tcp/127.0.0.1/8686
printf 'GET /health HTTP/1.0\r\n\r\n' >&3
grep -q '^HTTP/[0-9.]* 200' <&3
