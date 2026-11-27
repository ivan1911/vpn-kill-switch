# Stream diagnostics back to the process performing a one-shot mutation.
guard_debug() {
    [ -n "${VPN_KS_DEBUG_MARKER:-}" ] || return 0
    printf '%s %s %s\n' "$VPN_KS_DEBUG_MARKER" "$1" "$2" >&2 || :
}
