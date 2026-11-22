#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
temp_dir=$(mktemp -d)
archive="$temp_dir/redis-data.tar"
suffix="${temp_dir##*/}"
suffix="${suffix//[^a-zA-Z0-9]/}"
source_project="hw3check-${suffix,,}-source"
restore_project="hw3check-${suffix,,}-restore"
export HOST_PORT=
source=(docker compose -f compose.yaml -p "$source_project")
restore=(docker compose -f compose.yaml -p "$restore_project")
source_active=0
restore_active=0
stage="подготовка"

cleanup() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        printf 'Ошибка на этапе «%s» (код %s)\n' "$stage" "$result" >&2
    fi
    if (( restore_active == 1 )) && ! "${restore[@]}" down -v; then
        printf 'Не удалось очистить %s\n' "$restore_project" >&2
        result=1
    fi
    if (( source_active == 1 )) && ! "${source[@]}" down -v; then
        printf 'Не удалось очистить %s\n' "$source_project" >&2
        result=1
    fi
    if ! rm -f -- "$archive" || ! rmdir -- "$temp_dir"; then
        printf 'Не удалось очистить временный каталог проверки\n' >&2
        result=1
    fi
    if (( result == 0 )); then
        printf 'OK: все проверки пройдены\n'
    fi
    exit "$result"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

begin() {
    stage=$1
    printf '\n== %s ==\n' "$stage"
}

request() {
    curl --connect-timeout 2 --max-time 20 --silent --show-error "$@"
}

expect_count() {
    local expected=$1 method=$2 path=$3 json
    local count_pattern='"count"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*[,}]'
    json=$(request --fail -X "$method" "$base$path")
    if [[ ! $json =~ $count_pattern || ${BASH_REMATCH[1]} != "$expected" ]]; then
        printf 'Ожидался count=%s, ответ: %s\n' "$expected" "$json" >&2
        return 1
    fi
    printf '%s %s → count=%s\n' "$method" "$path" "$expected"
}

expect_status() {
    local expected=$1 method=$2 path=$3 status
    status=$(request -o /dev/null -w '%{http_code}' -X "$method" "$base$path")
    if [[ $status != "$expected" ]]; then
        printf '%s %s: ожидался HTTP %s, получен %s\n' "$method" "$path" "$expected" "$status" >&2
        return 1
    fi
    printf '%s %s → HTTP %s\n' "$method" "$path" "$status"
}

use_app_address() {
    local address
    address=$("$@" port app 8000)
    base="http://$address"
}

wait_until_ready() {
    local deadline=$((SECONDS + 45))
    until request --fail "$base/readyz" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            printf 'Приложение не стало готовым за 45 секунд\n' >&2
            return 1
        fi
        sleep 1
    done
}

begin "чистый проект и первые запросы"
source_active=1
"${source[@]}" up --build --wait --wait-timeout 60
use_app_address "${source[@]}"
expect_count 0 GET /
increments=3
for ((value=1; value<=increments; value++)); do
    expect_count "$value" POST /increment
done
expect_count "$increments" GET /

begin "пересоздание контейнера приложения"
"${source[@]}" up --wait --wait-timeout 60 --no-deps --force-recreate app
use_app_address "${source[@]}"
expect_count "$increments" GET /

begin "остановка и повторный запуск Redis"
"${source[@]}" stop redis
expect_status 200 GET /healthz
expect_status 503 GET /readyz
expect_status 503 POST /increment
"${source[@]}" start redis
wait_until_ready
expect_count "$increments" GET /
after_recovery=$((increments + 1))
expect_count "$after_recovery" POST /increment

begin "резервная копия и удаление исходного проекта"
"${source[@]}" stop app redis
"${source[@]}" run --rm --no-deps -T --user 0 --entrypoint tar redis -C /data -cpf - . >"$archive"
[[ -s $archive ]]
"${source[@]}" down -v
source_active=0

begin "восстановление в новый проект"
restore_active=1
"${restore[@]}" run --rm --no-deps -T --user 0 --entrypoint tar redis -C /data -xpf - <"$archive"
"${restore[@]}" up --wait --wait-timeout 60
use_app_address "${restore[@]}"
expect_count "$after_recovery" GET /
expect_count "$((after_recovery + 1))" POST /increment
