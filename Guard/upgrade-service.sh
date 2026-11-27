# Invoked by Apply while it holds the guard lock and the old selection is still active.
upgrade_service() (
    service_plist=/Library/LaunchDaemons/$label.plist
    [ -f "$service_plist" ] && [ -x "$base/guard" ] || {
        echo 'Installed VPN service is incomplete. Reinstall the kill switch before switching clients.' >&2
        exit 1
    }
    # @@UPGRADED_GUARD@@
    # @@UPGRADED_POLICY@@
    # @@UPGRADED_REMOVE@@
    /bin/sh -n "$stage/remove.next" && chmod 755 "$stage/remove.next" || exit 1
    if [ -f "$base/remove" ]; then cp -p "$base/remove" "$stage/remove.previous" || exit 1; fi
    /bin/sh -n "$stage/guard.next" && /bin/sh -n "$stage/policy.next" || exit 1
    chmod 755 "$stage/guard.next" && chmod 644 "$stage/policy.next" || exit 1

    cp -p "$base/guard" "$stage/guard.previous" || exit 1
    if [ -f "$base/policy.sh" ]; then cp -p "$base/policy.sh" "$stage/policy.previous" || exit 1; fi
    was_loaded=no
    if launchctl print "system/$label" >/dev/null 2>&1; then was_loaded=yes; fi
    restore_service() {
        rc=$?
        trap - EXIT HUP INT TERM
        if [ "$rc" -ne 0 ]; then
            if [ -f "$stage/remove.previous" ]; then mv -f "$stage/remove.previous" "$base/remove" || exit 1
            else rm -f "$base/remove" || exit 1; fi
            mv -f "$stage/guard.previous" "$base/guard" || exit 1
            if [ -f "$stage/policy.previous" ]; then
                mv -f "$stage/policy.previous" "$base/policy.sh" || exit 1
            else
                rm -f "$base/policy.sh" || exit 1
            fi
        fi
        exit "$rc"
    }
    trap restore_service EXIT
    trap 'exit 1' HUP INT TERM

    mv -f "$stage/remove.next" "$base/remove" || exit 1
    mv -f "$stage/policy.next" "$base/policy.sh" || exit 1
    mv -f "$stage/guard.next" "$base/guard" || exit 1
    if [ "$was_loaded" = yes ]; then
        # Retire any old worker that sampled Shadowrocket before taking the lock.
        # The launchd job remains registered even if the Apply process is interrupted.
        launchctl kickstart -k "system/$label" || exit 1
    else
        launchctl bootstrap system "$service_plist" || exit 1
    fi
)
