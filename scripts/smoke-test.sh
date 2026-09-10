#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="${1:-sub2api-pterodactyl:smoke}"
readonly CONTAINER="sub2api-pterodactyl-smoke"

cleanup() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d \
    --name "${CONTAINER}" \
    --memory 2g \
    -p 127.0.0.1:18080:8080 \
    "${IMAGE}" >/dev/null

for _ in $(seq 1 180); do
    if curl --fail --silent --show-error http://127.0.0.1:18080/health >/dev/null; then
        docker stop --time 45 "${CONTAINER}" >/dev/null
        exit_code="$(docker inspect --format '{{.State.ExitCode}}' "${CONTAINER}")"
        if [ "${exit_code}" -ne 0 ]; then
            echo "Container exited with status ${exit_code} after a normal stop."
            docker logs "${CONTAINER}"
            exit 1
        fi
        echo "Sub2API all-in-one smoke test passed."
        exit 0
    fi

    if [ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER}")" != "true" ]; then
        echo "Container exited before becoming healthy."
        docker logs "${CONTAINER}"
        exit 1
    fi
    sleep 1
done

echo "Timed out waiting for Sub2API."
docker logs "${CONTAINER}"
exit 1
