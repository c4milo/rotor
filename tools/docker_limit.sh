#!/usr/bin/env bash
#
# docker_limit: the time limit on each container that tools/linux_test.sh, tools/race_test.sh and
# tools/stress_test.sh start, and the function that holds a container to it. Those scripts source
# this file. It is never run on its own.
#
# A test that hangs in io_uring can hang for hours. Three runs hung before 2026-11-08, one for 4
# hours. A SIGKILL inside the container did not end the io_uring hang, and `docker kill` sends the
# same SIGKILL, so the container can stay. The limit bounds the time of the gate, whether or not
# the container dies. At the limit a watcher on the host runs `docker kill` on the container. When
# the docker client has not returned after a grace time, the watcher kills the client with SIGKILL.
# The script then fails, names the executable that hung, and says whether its container is gone.
#
# The host has no timeout(1) on macOS, so each bound is a background process that the script kills
# when its time ends. This needs no tool outside bash and docker. A docker call can block when the
# daemon blocks, so each docker call after the limit has a bound too. A gate that hangs ends after
# at most docker_limit_seconds, docker_limit_grace_seconds and two times docker_limit_call_seconds.
#
# Each container gets a unique name, so the watcher kills only its own container. A normal run
# ends the watcher at once and does not wait for it. The script's exit, an interrupt included,
# kills the watcher and the container that still runs.

# The limit, in seconds, on one container of the Linux gate or the race gate, and on the time
# between two finished runs of the stress gate. These are the longest times measured on `mac` on
# 2026-11-08, each the longest of two runs:
#
# - Linux gate: 5 s (`conformance-epoll`) at a load average of 10, and 25 s (`core`) at 39.
# - Race gate: 5 s (`conformance-epoll`) at a load average of 10 to 21.
# - Stress gate: 3 s between two finished runs, at a load average of 4 to 26.
#
# CI's Linux runners take about as long for the whole Linux gate as `mac` at a load of 10. 120 s
# is about 5 times the longest time, on a machine at a load of 39. It is far under the 15 minutes
# of a CI job, so a hang fails here with a name and not at the job's own timeout.
readonly docker_limit_seconds=120
# The time, in seconds, that the watcher gives `docker kill` and the docker client after the limit.
# The watcher then kills both with SIGKILL, so the script does not wait on them.
readonly docker_limit_grace_seconds=30
# The bound, in seconds, on one docker call that the script makes after the limit or at its exit.
readonly docker_limit_call_seconds=10
# The status the watcher exits with when it reached the limit.
readonly docker_limit_fired_status=3
# The status of a bounded call that was killed at its bound, as timeout(1) gives.
readonly docker_limit_timeout_status=124

# The container, docker client and watcher of the run in progress, and the bounded call in
# progress, for docker_limit_end.
docker_limit_container=''
docker_limit_client=''
docker_limit_watcher=''
docker_limit_call=''
# The number of containers this shell started, which makes each name unique.
docker_limit_count=0

# Runs a command with its output discarded, and kills it with SIGKILL after the given number of
# seconds. It returns the command's status, or docker_limit_timeout_status when it killed it.
docker_limit_bounded() {
  local seconds="$1"
  shift
  "$@" >/dev/null 2>&1 &
  docker_limit_call=$!
  local tenths=0
  while kill -0 "$docker_limit_call" 2>/dev/null && ((tenths < seconds * 10)); do
    sleep 0.1
    tenths=$((tenths + 1))
  done
  local status=0
  if kill -0 "$docker_limit_call" 2>/dev/null; then
    kill -KILL "$docker_limit_call" 2>/dev/null || true
    wait "$docker_limit_call" 2>/dev/null || true
    status="$docker_limit_timeout_status"
  else
    wait "$docker_limit_call" || status=$?
  fi
  docker_limit_call=''
  return "$status"
}

# Returns 0 when the named container is gone within docker_limit_call_seconds. It returns non-zero
# when the container is still there, or when docker did not answer.
docker_limit_gone() {
  local name="$1"
  # shellcheck disable=SC2016
  docker_limit_bounded "$docker_limit_call_seconds" sh -c '
    while :; do
      if ! out="$(docker container inspect --format x "$1" 2>&1)"; then
        case "$out" in *"No such"*) exit 0 ;; esac
      fi
      sleep 0.5
    done' sh "$name"
}

# Ends the run in progress, if there is one: its bounded call, its watcher, its container and its
# docker client.
docker_limit_end() {
  if [[ -n "$docker_limit_call" ]]; then
    kill -KILL "$docker_limit_call" 2>/dev/null || true
    docker_limit_call=''
  fi
  if [[ -n "$docker_limit_watcher" ]]; then
    kill "$docker_limit_watcher" 2>/dev/null || true
  fi
  if [[ -n "$docker_limit_container" ]]; then
    docker_limit_bounded "$docker_limit_call_seconds" docker kill "$docker_limit_container" || true
  fi
  if [[ -n "$docker_limit_client" ]]; then
    kill -KILL "$docker_limit_client" 2>/dev/null || true
  fi
}
trap docker_limit_end EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Watches one container. It returns 0 when it is killed with TERM before the limit, and
# docker_limit_fired_status when it reached the limit. With a progress file, the limit counts
# from the last time the file grew. Without one, it counts from the start.
docker_limit_watch() {
  local name="$1"
  local client="$2"
  local progress="$3"
  local fired=0
  local sleeper=''
  local killer=''
  local size=0
  local last_size=0
  local last_progress="$SECONDS"
  # The caller can run with errexit on, so no command here may fail.
  trap 'kill "$sleeper" 2>/dev/null || true
    if [[ -n "$killer" ]]; then kill -KILL "$killer" 2>/dev/null || true; fi
    exit $((fired ? docker_limit_fired_status : 0))' TERM
  while ((SECONDS - last_progress < docker_limit_seconds)); do
    sleep 1 &
    sleeper=$!
    wait "$sleeper" || true
    if [[ -n "$progress" ]]; then
      # The file does not exist until the first run ends.
      size="$({ wc -c <"$progress"; } 2>/dev/null || echo 0)"
      if ((size != last_size)); then
        last_size="$size"
        last_progress="$SECONDS"
      fi
    fi
  done
  # The TERM trap above reads it.
  # shellcheck disable=SC2034
  fired=1
  # `docker kill` can block, so it runs in the background, and the grace time bounds it.
  docker kill "$name" >/dev/null 2>&1 &
  killer=$!
  local waited=0
  while kill -0 "$client" 2>/dev/null && ((waited < docker_limit_grace_seconds)); do
    sleep 1 &
    sleeper=$!
    wait "$sleeper" || true
    waited=$((waited + 1))
  done
  # The SIGKILL to the client ends the wait of docker_limit_run, whether or not the container died.
  kill -KILL "$client" 2>/dev/null || true
  kill -KILL "$killer" 2>/dev/null || true
  exit "$docker_limit_fired_status"
}

# Removes the container of a run that reached the limit, and prints what became of it.
docker_limit_report() {
  local label="$1"
  local name="$2"
  # The scripts that source this file hold names of their own, `script` among them.
  local gate="${0##*/}"
  gate="${gate%.sh}"
  # The container has --rm, so docker can remove it after the kill. This call is for a container
  # that the kill did not end.
  docker_limit_bounded "$docker_limit_call_seconds" docker rm --force "$name" || true
  if docker_limit_gone "$name"; then
    echo "$gate: $label hung after $docker_limit_seconds s; the host killed its container" >&2
  else
    echo "$gate: $label hung after $docker_limit_seconds s; the host ended its docker client" >&2
    echo "$gate: container $name is still there; remove it by hand" >&2
  fi
}

# Runs `docker run` with a unique name and the given arguments, and ends the run at the limit.
# The first argument is the label the failure names, the executable that runs. The second is the
# progress file, or an empty string for none. It returns docker's status, or 1 after it printed
# that the label hung. Standard input is /dev/null, so a container cannot read the caller's input.
# Do not call it in a command substitution: an interrupt there leaves the watcher behind.
docker_limit_run() {
  local label="$1"
  local progress="$2"
  shift 2
  docker_limit_count=$((docker_limit_count + 1))
  # The name takes a random part too, so two scripts with the same process ID do not collide.
  local name="rotor-${0##*/}-$$-$docker_limit_count-$RANDOM$RANDOM"
  name="${name//[^a-zA-Z0-9_.-]/-}"
  docker_limit_container="$name"
  docker run --name "$name" "$@" </dev/null &
  docker_limit_client=$!
  docker_limit_watch "$name" "$docker_limit_client" "$progress" &
  docker_limit_watcher=$!
  local status=0
  wait "$docker_limit_client" || status=$?
  docker_limit_client=''
  kill "$docker_limit_watcher" 2>/dev/null || true
  local watcher_status=0
  wait "$docker_limit_watcher" || watcher_status=$?
  docker_limit_watcher=''
  if ((watcher_status == docker_limit_fired_status)); then
    docker_limit_report "$label" "$name"
    docker_limit_container=''
    return 1
  fi
  docker_limit_container=''
  return "$status"
}
