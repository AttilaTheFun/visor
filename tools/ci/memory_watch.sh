# How much memory a CI job in a Linux container used at most, for sizing
# the container: Shireworks' figure for a container counts the file cache
# too, which Linux fills up to the limit, so it is no measure of what a
# build needs. Sourced, not run:
#
#   . tools/ci/memory_watch.sh
#   memory_watch_start
#   …
#   memory_watch_report <what>
#
# memory_watch_start samples /proc/meminfo every two seconds in the
# background; memory_watch_report stops it and says, as a notice on the
# run's summary, the most in use (MemTotal − MemAvailable) and the most
# with the file cache (MemTotal − MemFree), against the container's memory.
# Where there is no /proc/meminfo (a Mac) both do nothing.

memory_watch_start() {
    [ -r /proc/meminfo ] || return 0
    MEMORY_WATCH_FILE="$(mktemp)"
    # Its output nowhere: a sampler left holding the job's log open would
    # keep the step from ending.
    (
        peak=0
        cached=0
        # Its sleep ended with it, so no process outlives the job's step.
        sleeper=""
        trap '[ -z "$sleeper" ] || kill "$sleeper" 2> /dev/null; exit 0' TERM
        while :; do
            set -- $(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } /^MemFree:/ { f = $2 } END { print t, a, f }' /proc/meminfo)
            if [ $(($1 - $2)) -gt "$peak" ]; then peak=$(($1 - $2)); fi
            if [ $(($1 - $3)) -gt "$cached" ]; then cached=$(($1 - $3)); fi
            echo "$1 $peak $cached" > "$MEMORY_WATCH_FILE.new" && mv -f "$MEMORY_WATCH_FILE.new" "$MEMORY_WATCH_FILE"
            sleep 2 &
            sleeper=$!
            wait "$sleeper" || true
        done
    ) > /dev/null 2>&1 &
    MEMORY_WATCH_PID=$!
}

memory_watch_report() {
    [ -n "${MEMORY_WATCH_PID:-}" ] || return 0
    kill "$MEMORY_WATCH_PID" 2> /dev/null || true
    wait "$MEMORY_WATCH_PID" 2> /dev/null || true
    MEMORY_WATCH_PID=""
    local total peak cached
    read -r total peak cached < "$MEMORY_WATCH_FILE" 2> /dev/null || return 0
    rm -f "$MEMORY_WATCH_FILE" "$MEMORY_WATCH_FILE.new"
    awk -v what="$1" -v t="$total" -v p="$peak" -v c="$cached" 'BEGIN {
        printf "::notice title=Memory, %s::at most %.1f GB in use (%.1f GB with the file cache) of the container'"'"'s %.1f GB\n", what, p / 1048576, c / 1048576, t / 1048576
    }'
}
