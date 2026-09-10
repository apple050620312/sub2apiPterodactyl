#!/bin/sh
set -eu

readonly DATA_ROOT="/home/container"
readonly APP_DATA="${DATA_ROOT}/data"
readonly PG_DATA="${DATA_ROOT}/postgres"
readonly REDIS_DATA="${DATA_ROOT}/redis"
readonly SECRET_FILE="${DATA_ROOT}/.sub2api-secrets"
readonly RUNTIME_DIR="/tmp/sub2api-pterodactyl"
readonly PG_SOCKET_DIR="${RUNTIME_DIR}/postgres"

PG_PID=""
REDIS_PID=""
APP_PID=""
STOPPING=0

log() {
    printf '[Sub2API/Pterodactyl] %s\n' "$*"
}

random_hex() {
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

configure_runtime_identity() {
    runtime_uid="$(id -u)"
    runtime_gid="$(id -g)"
    runtime_user="$(awk -F: -v uid="${runtime_uid}" '$3 == uid { print $1; exit }' /etc/passwd)"

    cp /etc/passwd "${RUNTIME_DIR}/passwd"
    cp /etc/group "${RUNTIME_DIR}/group"

    if [ -z "${runtime_user}" ]; then
        runtime_user="ptero${runtime_uid}"
        printf '%s:x:%s:%s:Pterodactyl runtime user:%s:/bin/sh\n' \
            "${runtime_user}" "${runtime_uid}" "${runtime_gid}" "${HOME}" \
            >> "${RUNTIME_DIR}/passwd"
    fi

    if ! awk -F: -v gid="${runtime_gid}" '$3 == gid { found=1 } END { exit !found }' /etc/group; then
        printf 'ptero%s:x:%s:\n' "${runtime_gid}" "${runtime_gid}" >> "${RUNTIME_DIR}/group"
    fi

    nss_library="$(find /usr/lib -name 'libnss_wrapper.so*' -type f | head -n 1)"
    if [ -z "${nss_library}" ]; then
        log "ERROR: nss_wrapper library was not found."
        exit 1
    fi

    export NSS_WRAPPER_PASSWD="${RUNTIME_DIR}/passwd"
    export NSS_WRAPPER_GROUP="${RUNTIME_DIR}/group"
    export LD_PRELOAD="${nss_library}"
    export USER="${runtime_user}"
    export LOGNAME="${runtime_user}"
}

load_or_create_secrets() {
    umask 077

    if [ ! -f "${SECRET_FILE}" ]; then
        secret_tmp="${SECRET_FILE}.tmp"
        {
            printf 'INTERNAL_DB_PASSWORD=%s\n' "$(random_hex)"
            printf 'JWT_SECRET=%s\n' "$(random_hex)"
            printf 'TOTP_ENCRYPTION_KEY=%s\n' "$(random_hex)"
        } > "${secret_tmp}"
        mv "${secret_tmp}" "${SECRET_FILE}"
        log "Generated persistent internal secrets."
    fi

    chmod 0600 "${SECRET_FILE}"
    INTERNAL_DB_PASSWORD="$(sed -n 's/^INTERNAL_DB_PASSWORD=//p' "${SECRET_FILE}")"
    JWT_SECRET="$(sed -n 's/^JWT_SECRET=//p' "${SECRET_FILE}")"
    TOTP_ENCRYPTION_KEY="$(sed -n 's/^TOTP_ENCRYPTION_KEY=//p' "${SECRET_FILE}")"

    for secret in "${INTERNAL_DB_PASSWORD}" "${JWT_SECRET}" "${TOTP_ENCRYPTION_KEY}"; do
        if ! printf '%s' "${secret}" | grep -Eq '^[0-9a-f]{64}$'; then
            log "ERROR: ${SECRET_FILE} is invalid. Restore it from backup or remove it together with all service data."
            exit 1
        fi
    done

    export INTERNAL_DB_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY
}

shutdown_services() {
    if [ "${STOPPING}" -eq 1 ]; then
        return
    fi
    STOPPING=1
    log "Stopping Sub2API and its internal services..."

    for pid in "${APP_PID}" "${PG_PID}" "${REDIS_PID}"; do
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done

    for pid in "${APP_PID}" "${PG_PID}" "${REDIS_PID}"; do
        if [ -n "${pid}" ]; then
            wait "${pid}" 2>/dev/null || true
        fi
    done
}

trap 'shutdown_services; exit 0' INT TERM

mkdir -p "${APP_DATA}" "${PG_DATA}" "${REDIS_DATA}" "${PG_SOCKET_DIR}"
chmod 0700 "${PG_DATA}" "${REDIS_DATA}" "${RUNTIME_DIR}" "${PG_SOCKET_DIR}"

configure_runtime_identity
load_or_create_secrets

first_database_init=0
if [ ! -s "${PG_DATA}/PG_VERSION" ]; then
    first_database_init=1
    password_file="${RUNTIME_DIR}/postgres-password"
    printf '%s\n' "${INTERNAL_DB_PASSWORD}" > "${password_file}"
    chmod 0600 "${password_file}"

    log "Initializing PostgreSQL 18..."
    initdb \
        --pgdata="${PG_DATA}" \
        --username=sub2api \
        --pwfile="${password_file}" \
        --auth-local=trust \
        --auth-host=scram-sha-256 \
        --encoding=UTF8 \
        --locale=C
    rm -f "${password_file}"
fi

log "Starting PostgreSQL..."
postgres \
    -D "${PG_DATA}" \
    -h 127.0.0.1 \
    -p 5432 \
    -k "${PG_SOCKET_DIR}" \
    -c unix_socket_permissions=0700 &
PG_PID=$!

postgres_ready=0
for attempt in $(seq 1 60); do
    if pg_isready -q -h "${PG_SOCKET_DIR}" -p 5432 -U sub2api; then
        postgres_ready=1
        break
    fi
    if ! kill -0 "${PG_PID}" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ "${postgres_ready}" -ne 1 ]; then
    log "ERROR: PostgreSQL did not become ready."
    shutdown_services
    exit 1
fi

if ! psql -h "${PG_SOCKET_DIR}" -p 5432 -U sub2api -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = 'sub2api'" | grep -q '^1$'; then
    createdb -h "${PG_SOCKET_DIR}" -p 5432 -U sub2api sub2api
fi

log "Starting Redis..."
redis-server \
    --bind 127.0.0.1 \
    --protected-mode yes \
    --port 6379 \
    --dir "${REDIS_DATA}" \
    --appendonly yes \
    --appendfsync everysec \
    --save 60 1 &
REDIS_PID=$!

redis_ready=0
for attempt in $(seq 1 30); do
    if redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q '^PONG$'; then
        redis_ready=1
        break
    fi
    if ! kill -0 "${REDIS_PID}" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ "${redis_ready}" -ne 1 ]; then
    log "ERROR: Redis did not become ready."
    shutdown_services
    exit 1
fi

export AUTO_SETUP=true
export SERVER_HOST=0.0.0.0
export SERVER_PORT="${SERVER_PORT:-8080}"
export SERVER_MODE="${SERVER_MODE:-release}"
export RUN_MODE="${RUN_MODE:-standard}"
export DATA_DIR="${APP_DATA}"
export DATABASE_HOST=127.0.0.1
export DATABASE_PORT=5432
export DATABASE_USER=sub2api
export DATABASE_PASSWORD="${INTERNAL_DB_PASSWORD}"
export DATABASE_DBNAME=sub2api
export DATABASE_SSLMODE=disable
export REDIS_HOST=127.0.0.1
export REDIS_PORT=6379
export REDIS_DB=0
export REDIS_ENABLE_TLS=false
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@sub2api.local}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
export TZ="${TZ:-Asia/Taipei}"

log "Starting Sub2API on 0.0.0.0:${SERVER_PORT}..."
cd /app
/app/sub2api &
APP_PID=$!

app_ready=0
for attempt in $(seq 1 120); do
    if wget -q -T 2 -O /dev/null "http://127.0.0.1:${SERVER_PORT}/health"; then
        app_ready=1
        break
    fi
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ "${app_ready}" -ne 1 ]; then
    log "ERROR: Sub2API did not become ready."
    shutdown_services
    exit 1
fi

log "Sub2API is ready. Open the server's primary allocation in your browser."
if [ -z "${ADMIN_PASSWORD}" ] && [ "${first_database_init}" -eq 1 ]; then
    log "The generated administrator password is shown in the Sub2API log above."
fi

exit_status=0
while :; do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        set +e
        wait "${APP_PID}"
        exit_status=$?
        set -e
        log "Sub2API exited with status ${exit_status}."
        break
    fi
    if ! kill -0 "${PG_PID}" 2>/dev/null; then
        log "ERROR: PostgreSQL exited unexpectedly."
        exit_status=1
        break
    fi
    if ! kill -0 "${REDIS_PID}" 2>/dev/null; then
        log "ERROR: Redis exited unexpectedly."
        exit_status=1
        break
    fi
    sleep 2
done

shutdown_services
exit "${exit_status}"
