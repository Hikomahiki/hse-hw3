# ДЗ 3 по Docker

Приложение на Python читает значение счётчика по GET / и увеличивает его по POST /increment. Сборка работает с исходным приложением из задания. На уровнях 4 и 6 используется SQLite, а на уровнях 8 и 10 используется Redis.

Запускайте команды в корне репозитория из Bash. Нужны запущенный Docker Engine, Docker Compose v2 и curl. В WSL проверьте доступ к Docker командами docker info и docker compose version.

## 4 балла · один контейнер

Порт 8080 хоста направляется на порт 8000 внутри контейнера. Переменная GREETING задаёт строку в ответе приложения.

~~~bash
docker build -t hse-hw3 .
docker run -d --name hw3-counter-4 \
  -p 127.0.0.1:8080:8000 -e 'GREETING=Hello, HSE!' hse-hw3

curl -fsS --max-time 4 --retry 5 --retry-connrefused http://127.0.0.1:8080/readyz
curl -fsS http://127.0.0.1:8080/
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS http://127.0.0.1:8080/
mkdir -p checks
docker logs hw3-counter-4 2>&1 | tee checks/level-4.log
docker rm -f hw3-counter-4
~~~

Новый счётчик начинается с 0. Первый POST возвращает 1, и следующий GET возвращает то же значение.

## 6 баллов · Compose и SQLite

Создайте локальный .env командой cp -n .env.example .env. HOST_PORT задаёт опубликованный порт на компьютере, а GREETING задаёт приветствие. В примерах HOST_PORT равен 8080. Файл базы хранится в именованном томе sqlite_data.

~~~bash
docker compose -f compose.sqlite.yaml -p hw3-sqlite up --build --wait --wait-timeout 60
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS http://127.0.0.1:8080/
docker compose -f compose.sqlite.yaml -p hw3-sqlite down
docker compose -f compose.sqlite.yaml -p hw3-sqlite up --wait --wait-timeout 60
curl -fsS http://127.0.0.1:8080/
docker compose -f compose.sqlite.yaml -p hw3-sqlite down
~~~

Сравните ответы двух GET. После пересоздания контейнера count должен совпадать. Команда down сохраняет именованный том, а down -v удаляет его.

## 8 баллов · Compose и Redis

Приложение подключается к сервису redis по адресу redis://redis:6379/0 внутри сети Compose. На хост публикуется только порт приложения. Redis пишет журнал AOF на том redis_data. Проверка приложения использует /readyz, а проверка Redis использует redis-cli ping.

~~~bash
docker compose -p hw3-redis up --build --wait --wait-timeout 60
docker compose -p hw3-redis ps
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS http://127.0.0.1:8080/

docker compose -p hw3-redis down
docker compose -p hw3-redis up --wait --wait-timeout 60
curl -fsS http://127.0.0.1:8080/

docker compose -p hw3-redis stop redis
curl -sS --max-time 4 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/healthz
curl -sS --max-time 4 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz
curl -sS --max-time 4 -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8080/increment

docker compose -p hw3-redis start redis
curl -fsS --max-time 4 --retry 12 --retry-max-time 45 --retry-connrefused \
  http://127.0.0.1:8080/readyz
curl -fsS http://127.0.0.1:8080/
curl -fsS -X POST http://127.0.0.1:8080/increment
docker compose -p hw3-redis down
~~~

После пересоздания Compose счётчик должен вернуть прежнее N. Пока Redis выключен, ожидаются коды 200, 503 и 503 в указанном порядке. После запуска Redis счётчик возвращает N, а следующий POST возвращает N + 1.

## 10 баллов · ограничения и восстановление

В compose.yaml приложение работает с UID 10001 и корневой файловой системой только для чтения. Лимиты приложения составляют 256 MiB RAM и 1 CPU.

Скрипт проверяет чистый счётчик, пересоздаёт контейнер приложения, останавливает и запускает Redis. Затем он останавливает оба сервиса, копирует содержимое /data во временный tar-архив, удаляет исходный тестовый том и проверяет значение после восстановления в новый том. Для каждого запуска создаются отдельные проекты и Docker назначает свободные порты.

~~~bash
mkdir -p checks
chmod +x scripts/check.sh
set -o pipefail
./scripts/check.sh 2>&1 | tee checks/level-10-run-1.log &&
  ./scripts/check.sh 2>&1 | tee checks/level-10-run-2.log
~~~

В чистом тестовом проекте три POST дают count=3. После перезапуска Redis следующий POST даёт 4. После восстановления из архива GET возвращает 4 и следующий POST возвращает 5.

Условия работы находятся в [задании курса](https://github.com/Nikfilk2030/missing_semester_hse_cs/tree/main/2026/amcs/year_1/hw_3).
