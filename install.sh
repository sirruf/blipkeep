#!/usr/bin/env bash
#
# Установка панели в одну команду — вместе с тем, что обычно приходится
# выяснять отдельно: где лежит пароль администратора, откуда взять
# enrollment-токен и какой именно командой ставить агента.
#
#   sudo ./install.sh --host mon.example.com
#
# Панель разворачивает server/bootstrap, здесь только его вызов и то, что
# идёт после: токен и готовая к вставке команда для наблюдаемого сервера.
# Ради неё скрипт и существует: собрать её руками из адреса, схемы и токена
# можно, но именно на этом шаге установка обычно и застревает.

set -euo pipefail

cd "$(dirname "$0")"

case "${TINYMON_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
  en*|C|POSIX) MSG_LANG="en" ;;
  *)           MSG_LANG="ru" ;;
esac

# t <русский текст> <english text>
t() {
  if [[ "$MSG_LANG" == "en" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

HOST=""
SCHEME="https"
STACK_NAME="tinymon"

# Аргументы разбираются, но не съедаются: bootstrap получает их все как есть,
# здесь нужны только те, из которых потом собирается команда для агента
for (( i = 1; i <= $#; i++ )); do
  case "${!i}" in
    --host)   j=$((i + 1)); HOST="${!j}" ;;
    --scheme) j=$((i + 1)); SCHEME="${!j}" ;;
    --stack)  j=$((i + 1)); STACK_NAME="${!j}" ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "$(t "Укажите адрес панели:" "Specify the panel address:")" >&2
  echo "  sudo ./install.sh --host mon.example.com" >&2
  echo >&2
  echo "$(t "Остальные параметры — ./server/bootstrap --help" \
           "For the other options see ./server/bootstrap --help")" >&2
  exit 1
fi

[[ $EUID -eq 0 ]] || {
  echo "$(t "требуются права root: запустите через sudo" \
           "root privileges required: run through sudo")" >&2
  exit 1
}

# ---- Панель ----------------------------------------------------------------

./server/bootstrap "$@"

# ---- Токен и команда для агента --------------------------------------------

container="$(docker ps -q -f "name=${STACK_NAME}_tinymon" | head -1)"

if [[ -z "$container" ]]; then
  echo "$(t "Панель развёрнута, но контейнер не найден — токен возьмите из панели, экран «Агенты»" \
           "The panel is deployed, but its container was not found — take the token from the panel, the Agents screen")" >&2
  exit 0
fi

echo
echo "==> $(t "создаю токен для подключения агентов" "creating an enrollment token for agents")"

# Токен печатается строкой ENROLLMENT_TOKEN=<значение>; вытаскиваем значение,
# чтобы сразу подставить его в команду, а не заставлять копировать из вывода
token_output="$(docker exec "$container" /app/bin/tinymon eval \
  'Tinymon.Release.enrollment_token()' 2>/dev/null || true)"

TOKEN="$(printf '%s' "$token_output" | grep -o 'ENROLLMENT_TOKEN=.*' | cut -d= -f2- | tr -d '\r')"

if [[ -z "$TOKEN" ]]; then
  echo "    $(t "не удалось — создайте токен в панели на экране «Агенты»" \
                "failed — create a token in the panel on the Agents screen")" >&2
  exit 0
fi

WS_SCHEME="wss"
[[ "$SCHEME" == "https" ]] || WS_SCHEME="ws"

cat <<EOF

────────────────────────────────────────────────────────────────────────

$(t "ПАНЕЛЬ ГОТОВА" "THE PANEL IS READY"): ${SCHEME}://${HOST}

$(t "Вход:" "Sign in:")
  $(t "почта и пароль лежат в" "email and password are in") /opt/tinymon/.initial-credentials
  $(t "пароль придётся сменить при первом входе" "you will have to change the password on first sign-in")

$(t "Установка агента — выполните на наблюдаемом сервере:" \
     "Installing an agent — run this on the server you want to monitor:")

  curl -fsSL ${SCHEME}://${HOST}/install.sh | sudo bash -s -- \\
    --server ${WS_SCHEME}://${HOST}/agent \\
    --token ${TOKEN}

$(t "Установщик напечатает отпечаток ключа. Сверьте его в панели на экране" \
     "The installer prints a key fingerprint. Compare it in the panel on the")
$(t "«Агенты» и одобрите заявку — после этого хост появится в обзоре." \
     "Agents screen and approve the request — the host then appears in the overview.")

$(t "Токен многоразовый: той же командой ставится вся партия серверов." \
     "The token is reusable: the same command enrolls a whole batch of servers.")

────────────────────────────────────────────────────────────────────────
EOF
