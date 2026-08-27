#!/usr/bin/env bash
set -euo pipefail

EDGE_IMAGE="public.ecr.aws/supabase/edge-runtime:v1.74.3"
EDGE_DIGEST="public.ecr.aws/supabase/edge-runtime@sha256:c52405002a890ca9fcf77978671c57f3a988e03174afb277f84ac65bc917013c"
DENO_IMAGE="denoland/deno:2.1.4"
DENO_CONTAINER="pfh-edge-math-deno-control"
EDGE_CONTAINER="pfh-edge-math-v1743-control"
DENO_PORT="19001"
EDGE_PORT="19002"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DENO_CREATED=0
EDGE_CREATED=0

EXPECTED_JSON='{"E":{"value":"2.7182818284590451","bits":"4005bf0a8b145769"},"LN2":{"value":"0.69314718055994529","bits":"3fe62e42fefa39ef"},"LN10":{"value":"2.3025850929940459","bits":"40026bb1bbb55516"},"LOG2E":{"value":"1.4426950408889634","bits":"3ff71547652b82fe"},"LOG10E":{"value":"0.43429448190325182","bits":"3fdbcb7b1526e50e"},"PI":{"value":"3.1415926535897931","bits":"400921fb54442d18"},"SQRT1_2":{"value":"0.70710678118654757","bits":"3fe6a09e667f3bcd"},"SQRT2":{"value":"1.4142135623730951","bits":"3ff6a09e667f3bcd"}}'

KNOWN_FAILURE_JSON='{"E":{"value":"2.0000000000000000","bits":"4000000000000000"},"LN2":{"value":"0.0000000000000000","bits":"0000000000000000"},"LN10":{"value":"2.0000000000000000","bits":"4000000000000000"},"LOG2E":{"value":"1.0000000000000000","bits":"3ff0000000000000"},"LOG10E":{"value":"0.0000000000000000","bits":"0000000000000000"},"PI":{"value":"3.1415926535897931","bits":"400921fb54442d18"},"SQRT1_2":{"value":"0.70710678118654757","bits":"3fe6a09e667f3bcd"},"SQRT2":{"value":"1.4142135623730951","bits":"3ff6a09e667f3bcd"}}'

cleanup() {
  if [[ "$EDGE_CREATED" -eq 1 ]]; then
    docker stop "$EDGE_CONTAINER" >/dev/null 2>&1 || true
    docker rm "$EDGE_CONTAINER" >/dev/null 2>&1 || true
  fi

  if [[ "$DENO_CREATED" -eq 1 ]]; then
    docker stop "$DENO_CONTAINER" >/dev/null 2>&1 || true
    docker rm "$DENO_CONTAINER" >/dev/null 2>&1 || true
  fi
}

on_error() {
  local exit_code=$?
  trap - ERR
  printf '%s\n' "CLASSIFICATION=CASE_INFRA_FAILURE"
  exit "$exit_code"
}

wait_for_url() {
  local url=$1
  local container=$2
  local attempt

  for attempt in $(seq 1 30); do
    if curl --fail --silent --show-error "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  docker logs "$container" || true
  return 1
}

trap cleanup EXIT
trap on_error ERR

printf '%s\n' '=== HOST ==='
uname -a
uname -m
docker version
docker info

for container in "$DENO_CONTAINER" "$EDGE_CONTAINER"; do
  if docker container inspect "$container" >/dev/null 2>&1; then
    printf 'Temporary container name already exists: %s\n' "$container" >&2
    false
  fi
done

printf '%s\n' '=== IMAGES ==='
docker pull "$DENO_IMAGE"
docker pull "$EDGE_IMAGE"

docker image inspect "$EDGE_IMAGE" --format 'RepoDigests={{json .RepoDigests}}
Id={{.Id}}
Architecture={{.Architecture}}
Os={{.Os}}
Created={{.Created}}'

EDGE_REPO_DIGESTS="$(docker image inspect "$EDGE_IMAGE" --format '{{join .RepoDigests " "}}')"

if [[ " $EDGE_REPO_DIGESTS " != *" $EDGE_DIGEST "* ]]; then
  printf 'Unexpected edge-runtime digest: %s\n' "$EDGE_REPO_DIGESTS" >&2
  false
fi

printf '%s\n' '=== ORACLE ==='
printf 'EXPECTED_JSON=%s\n' "$EXPECTED_JSON"

printf '%s\n' '=== DENO 2.1.4 CONTROL ==='
docker run --rm "$DENO_IMAGE" --version

docker run --detach \
  --name "$DENO_CONTAINER" \
  --publish "127.0.0.1:${DENO_PORT}:8000" \
  --mount "type=bind,src=${SCRIPT_DIR}/index.ts,dst=/probe/index.ts,readonly" \
  "$DENO_IMAGE" \
  run --allow-net=0.0.0.0:8000 /probe/index.ts >/dev/null

DENO_CREATED=1

wait_for_url "http://127.0.0.1:${DENO_PORT}/" "$DENO_CONTAINER"

DENO_JSON="$(curl --fail --silent --show-error "http://127.0.0.1:${DENO_PORT}/")"
printf 'DENO_CONTROL_JSON=%s\n' "$DENO_JSON"

docker stop "$DENO_CONTAINER" >/dev/null
docker rm "$DENO_CONTAINER" >/dev/null
DENO_CREATED=0

if [[ "$DENO_JSON" != "$EXPECTED_JSON" ]]; then
  printf '%s\n' 'Deno control did not match the oracle.' >&2
  false
fi

printf '%s\n' '=== EDGE RUNTIME v1.74.3 ==='

docker run --detach \
  --name "$EDGE_CONTAINER" \
  --publish "127.0.0.1:${EDGE_PORT}:9000" \
  --mount "type=bind,src=${SCRIPT_DIR},dst=/probe,readonly" \
  "$EDGE_IMAGE" \
  start --main-service=/probe --port=9000 --policy=per_worker >/dev/null

EDGE_CREATED=1

wait_for_url "http://127.0.0.1:${EDGE_PORT}/" "$EDGE_CONTAINER"

EDGE_JSON="$(curl --fail --silent --show-error "http://127.0.0.1:${EDGE_PORT}/")"
printf 'EDGE_RUNTIME_JSON=%s\n' "$EDGE_JSON"

docker stop "$EDGE_CONTAINER" >/dev/null
docker rm "$EDGE_CONTAINER" >/dev/null
EDGE_CREATED=0

if [[ "$EDGE_JSON" == "$EXPECTED_JSON" ]]; then
  printf '%s\n' 'CLASSIFICATION=CASE_LINUX_PASS'
elif [[ "$EDGE_JSON" == "$KNOWN_FAILURE_JSON" ]]; then
  printf '%s\n' 'CLASSIFICATION=CASE_LINUX_FAIL_SAME'
else
  printf '%s\n' 'CLASSIFICATION=CASE_LINUX_FAIL_DIFFERENT'
fi
