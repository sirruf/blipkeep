#!/usr/bin/env bash
#
# Обновление панели до опубликованной версии. Запускается на самом сервере.
#
#   ./update.sh 0.7.0     — перевести стек на sirruf/tinymon-server:0.7.0
#   ./update.sh latest    — на последнюю опубликованную
#   ./update.sh --current — показать, что стоит сейчас
#
# Исходники и Elixir на сервере не нужны: образ приходит готовым из реестра.
# Откат — это тот же вызов с прежней версией, образ никуда не делся.
#
# Миграции применяет сам контейнер при старте (rel/overlays/bin/server),
# отдельного шага нет.

set -euo pipefail

# Язык сообщений: TINYMON_LANG, иначе локаль системы. Панель ставят и те, кто
# по-русски не читает, а вывод обновления — половина инструкции по откату
case "${TINYMON_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
  en*|C|POSIX) MSG_LANG="en" ;;
  *)           MSG_LANG="ru" ;;
esac

# t <русский текст> <english text>
t() {
  if [[ "$MSG_LANG" == "en" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

IMAGE="${TINYMON_IMAGE:-sirruf/tinymon-server}"
STACK_NAME="${STACK_NAME:-tinymon}"
SERVICE="${STACK_NAME}_tinymon"
VERSION="${1:-}"

cd "$(dirname "$0")"

current_version() {
  docker service inspect "$SERVICE" \
    --format '{{index .Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true
}

if [[ "$VERSION" == "--current" ]]; then
  echo "$(t "сейчас:" "current:") $(current_version)"
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  echo "$(t "Укажите версию: ./update.sh 0.7.0 (или latest)" "Specify a version: ./update.sh 0.7.0 (or latest)")" >&2
  echo "$(t "Сейчас стоит:" "Currently installed:") $(current_version)" >&2
  exit 1
fi

if ! docker service inspect "$SERVICE" >/dev/null 2>&1; then
  echo "$(t "Сервис $SERVICE не найден — стек ещё не развёрнут." "Service $SERVICE not found — the stack is not deployed yet.")" >&2
  echo "$(t "Первое развёртывание делается через deploy.sh." "The first deployment is done with deploy.sh.")" >&2
  exit 1
fi

BEFORE="$(current_version)"
echo "==> $(t "было:" "was:") $BEFORE"
echo "==> $(t "тяну" "pulling") ${IMAGE}:${VERSION}"

# Скачиваем заранее: если тега нет или нет доступа в реестр, узнаем об этом
# до того, как Swarm остановит работающий контейнер
docker pull "${IMAGE}:${VERSION}"

echo "==> $(t "перевожу" "updating") $SERVICE"

# --with-registry-auth передаёт узлам учётные данные реестра; для приватного
# репозитория без него задача не сможет скачать образ
docker service update \
  --with-registry-auth \
  --image "${IMAGE}:${VERSION}" \
  "$SERVICE"

echo "==> $(t "жду готовности" "waiting until it is ready")"

attempts=0
until [[ "$(docker service ls --filter "name=${SERVICE}" --format '{{.Replicas}}' | cut -d/ -f1)" == "1" ]]; do
  attempts=$((attempts + 1))

  if [[ $attempts -gt 90 ]]; then
    echo >&2
    echo "    $(t "сервис не поднялся за 3 минуты. Что случилось:" "the service did not start within 3 minutes. What happened:")" >&2
    docker service ps "$SERVICE" --no-trunc | head -5 >&2
    echo >&2
    echo "    $(t "откат: ./update.sh <версия из строки «было»>" "rollback: ./update.sh <the version from the \"was\" line>")" >&2
    exit 1
  fi

  sleep 2
done

echo
echo "==> $(t "готово:" "done:") $(current_version)"
