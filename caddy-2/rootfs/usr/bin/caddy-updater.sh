#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant App: Caddy 2
#
# Publishes a Home Assistant update entity (via MQTT discovery) for the custom
# Caddy binary at /config/caddy:
#   - installed version: what `/config/caddy version` reports
#   - latest version:    caddyserver/caddy's latest stable GitHub release
#   - Install:           `caddy upgrade` (same plugins, latest Caddy), then an
#                        add-on restart so the new binary is what runs.
#
# The built-in binary is updated with the add-on image instead, so nothing is
# published unless a custom binary is present.
# ==============================================================================

readonly CADDY_BIN="/config/caddy"
readonly CHECK_INTERVAL=$((6 * 3600))
readonly TOPIC="caddy-2/update"
readonly DISCOVERY_TOPIC="homeassistant/update/caddy_2_caddy/config"
readonly CLIENT_ID="caddy-2-updater"
# Shared with caddy.sh: whoever holds it owns /config/caddy and caddy.bak
# (an upgrade here, or caddy.sh's startup upgrade and validation).
readonly BINARY_LOCK="/run/caddy-binary.lock"

idle() {
    # Exiting would make s6 restart this service every second.
    exec sleep infinity
}

MQTT_ARGS=()
PUB_FAILED=false

load_mqtt() {
    MQTT_ARGS=(
        -h "$(bashio::services mqtt 'host')"
        -p "$(bashio::services mqtt 'port')"
        -u "$(bashio::services mqtt 'username')"
        -P "$(bashio::services mqtt 'password')"
    )
    if bashio::var.true "$(bashio::services mqtt 'ssl')"; then
        MQTT_ARGS+=(--capath /etc/ssl/certs)
    fi
}

pub() {
    # pub <topic> <payload> [extra mosquitto_pub args...]
    # Never fails (so errexit can't kill the loop); sets PUB_FAILED instead.
    local topic="$1" payload="$2"
    shift 2
    if ! mosquitto_pub "${MQTT_ARGS[@]}" -i "${CLIENT_ID}-pub" -q 1 "$@" -t "${topic}" -m "${payload}"; then
        bashio::log.warning "Couldn't publish to MQTT topic ${topic}"
        PUB_FAILED=true
    fi
}

disabled_reason=""
if bashio::config.false 'update_entity'; then
    disabled_reason="disabled (update_entity: false)"
elif ! bashio::fs.file_exists "${CADDY_BIN}"; then
    disabled_reason="not needed: no custom Caddy binary (the add-on update covers the built-in one)"
fi
if [ -n "${disabled_reason}" ]; then
    bashio::log.info "Caddy update entity ${disabled_reason}"
    if bashio::services.available "mqtt"; then
        # Remove an entity published while it was enabled.
        load_mqtt
        mosquitto_pub "${MQTT_ARGS[@]}" -i "${CLIENT_ID}-pub" -q 1 -r -n -t "${DISCOVERY_TOPIC}" \
            || bashio::log.warning "Couldn't clear the Caddy update entity"
    fi
    idle
fi

# The broker may be installed after this add-on starts.
if ! bashio::services.available "mqtt"; then
    bashio::log.info "No MQTT broker available yet; the Caddy update entity will appear once there is one"
    until bashio::services.available "mqtt"; do
        sleep 300
    done
fi
load_mqtt

LATEST_VERSION=""
LATEST_URL=""
LAST_CHECK=0
NEED_ANNOUNCE=false

installed_version() {
    "${CADDY_BIN}" version 2>/dev/null | awk '{print $1}'
}

check_latest() {
    local release
    if release=$(curl -fsSL --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/repos/caddyserver/caddy/releases/latest); then
        LATEST_VERSION=$(jq -r '.tag_name' <<<"${release}")
        LATEST_URL=$(jq -r '.html_url' <<<"${release}")
        LAST_CHECK=$(date +%s)
    else
        bashio::log.warning "Couldn't fetch the latest Caddy release; will retry"
        # Try again in ~15 minutes rather than waiting a full interval.
        LAST_CHECK=$(($(date +%s) - CHECK_INTERVAL + 900))
    fi
}

publish_state() {
    local in_progress="${1:-false}" installed
    installed=$(installed_version)
    pub "${TOPIC}/state" "$(jq -cn \
        --arg installed "${installed}" \
        --arg latest "${LATEST_VERSION:-${installed}}" \
        --arg url "${LATEST_URL}" \
        --argjson in_progress "${in_progress}" \
        '{installed_version: $installed, latest_version: $latest, title: "Caddy",
          in_progress: $in_progress} + (if $url != "" then {release_url: $url} else {} end)')" -r
}

publish_discovery() {
    pub "${DISCOVERY_TOPIC}" "$(jq -cn \
        --arg topic "${TOPIC}" \
        --arg addon_version "$(bashio::addon.version)" \
        '{
          name: null,
          unique_id: "caddy_2_addon_caddy",
          default_entity_id: "update.caddy",
          state_topic: "\($topic)/state",
          command_topic: "\($topic)/install",
          payload_install: "install",
          availability_topic: "\($topic)/availability",
          device: {
            identifiers: ["caddy_2_addon"],
            name: "Caddy",
            manufacturer: "Caddy",
            model: "Caddy 2 add-on",
            sw_version: $addon_version
          },
          origin: {name: "Caddy 2 add-on", sw_version: $addon_version,
                   support_url: "https://github.com/caraar12345/hass-addon-caddy-2"}
        }')" -r
}

upgrade() {
    exec 8> "${BINARY_LOCK}"
    if ! flock -n 8; then
        bashio::log.warning "Caddy's startup is upgrading or validating the binary; ignoring Install"
        publish_state false
        exec 8>&-
        return
    fi
    do_upgrade
    exec 8>&-
}

do_upgrade() {
    local before after old_modules new_modules
    before=$(installed_version)
    # caddy.bak is the rollback for an upgrade caddy.sh hasn't validated yet;
    # don't overwrite it with the unvalidated binary.
    if bashio::fs.file_exists "${CADDY_BIN}.upgraded"; then
        bashio::log.warning "The last upgrade hasn't been validated yet (add-on restart pending); ignoring Install"
        publish_state false
        return
    fi
    bashio::log.info "Upgrading Caddy ${before} with the same plugins..."
    publish_state true

    cp -p "${CADDY_BIN}" "${CADDY_BIN}.bak"
    old_modules=$("${CADDY_BIN}" list-modules -s 2>/dev/null | sort)

    if ! "${CADDY_BIN}" upgrade; then
        bashio::log.error "caddy upgrade failed; keeping ${before}"
        cp -p "${CADDY_BIN}.bak" "${CADDY_BIN}"
        publish_state false
        return
    fi

    # The download server rebuilds from the plugin list; refuse a binary that
    # doesn't run or came back with different plugins.
    after=$(installed_version)
    new_modules=$("${CADDY_BIN}" list-modules -s 2>/dev/null | sort)
    if [ -z "${after}" ] || [ "${old_modules}" != "${new_modules}" ]; then
        bashio::log.error "Upgraded binary doesn't run or has different plugins; restoring ${before}"
        diff <(echo "${old_modules}") <(echo "${new_modules}") || true
        cp -p "${CADDY_BIN}.bak" "${CADDY_BIN}"
        publish_state false
        return
    fi

    # Same Caddy version can still mean rebuilt plugins, so compare the files.
    if cmp -s "${CADDY_BIN}" "${CADDY_BIN}.bak"; then
        bashio::log.info "Caddy is already at ${after} with the latest plugins"
        publish_state false
        return
    fi

    # caddy.sh validates the config with the new binary on the next start and
    # goes back to caddy.bak if it can't load it.
    touch "${CADDY_BIN}.upgraded"
    bashio::log.info "Caddy upgraded ${before} -> ${after} (previous binary kept at ${CADDY_BIN}.bak); restarting the add-on"
    publish_state true
    bashio::addon.restart
}

CONN_PID=""
readonly FIFO="/tmp/caddy-updater.fifo"
PENDING_INSTALL=false

connect() {
    # One long-lived connection that carries the retained "offline" last
    # will AND receives Install commands, read by the main loop through a
    # FIFO. If it dies at any point, the broker publishes the will and the
    # loop's next read hits EOF straight away, so "online" can never stay
    # retained without a live will behind it.
    # Returns success only once a probe published to its own topic comes
    # back through it, i.e. it's connected and subscribed.
    [ -z "${CONN_PID}" ] || kill "${CONN_PID}" 2>/dev/null || true
    exec 7<&- 2>/dev/null || true
    rm -f "${FIFO}"
    mkfifo "${FIFO}"
    # Persistent QoS 1 session (-c): an Install pressed while disconnected is
    # delivered on reconnect.
    mosquitto_sub "${MQTT_ARGS[@]}" -i "${CLIENT_ID}-sub" -c -q 1 -k 30 -v \
        --will-topic "${TOPIC}/availability" --will-payload offline --will-retain --will-qos 1 \
        -t "${TOPIC}/install" -t "${TOPIC}/will" > "${FIFO}" 2>/dev/null &
    CONN_PID=$!
    exec 7< "${FIFO}"

    local probe line rc deadline
    probe="probe-$$-$(date +%s%N)"
    deadline=$(($(date +%s) + 10))
    pub "${TOPIC}/will" "${probe}"
    while (($(date +%s) < deadline)); do
        if read -r -t 1 -u 7 line; then
            case "${line}" in
                "${TOPIC}/will ${probe}") return 0 ;;
                "${TOPIC}/install install") PENDING_INSTALL=true ;;
            esac
        else
            rc=$?
            ((rc > 128)) || break # EOF: the connection died
            pub "${TOPIC}/will" "${probe}"
        fi
    done
    bashio::log.warning "Couldn't confirm the MQTT connection; not marking the entity online yet"
    kill "${CONN_PID}" 2>/dev/null || true
    return 1
}

shutdown() {
    # A clean disconnect doesn't send the will, so publish offline ourselves.
    [ -z "${CONN_PID}" ] || kill "${CONN_PID}" 2>/dev/null || true
    pub "${TOPIC}/availability" "offline" -r || true
    exit 0
}
trap shutdown TERM INT

announce() {
    # Retained discovery and availability, republished periodically and after
    # MQTT failures in case the broker lost its retained messages.
    PUB_FAILED=false
    publish_discovery
    pub "${TOPIC}/availability" "online" -r
    publish_state false
    NEED_ANNOUNCE="${PUB_FAILED}"
}

check_latest
CONNECTED=false
if connect; then
    CONNECTED=true
    announce
else
    NEED_ANNOUNCE=true
fi
bashio::log.info "Caddy update entity started: installed $(installed_version), latest ${LATEST_VERSION:-unknown}"

while true; do
    if ! bashio::var.true "${CONNECTED}"; then
        if connect; then
            CONNECTED=true
            NEED_ANNOUNCE=true
        else
            sleep 60
            continue
        fi
    fi

    now=$(date +%s)
    # Any failed publish (including from upgrade()) means retained messages
    # may be missing or stale.
    if bashio::var.true "${PUB_FAILED}"; then
        NEED_ANNOUNCE=true
    fi
    if ((now - LAST_CHECK >= CHECK_INTERVAL)); then
        check_latest
        NEED_ANNOUNCE=true
    fi
    if bashio::var.true "${NEED_ANNOUNCE}"; then
        announce
    fi
    if bashio::var.true "${PENDING_INSTALL}"; then
        PENDING_INSTALL=false
        check_latest
        upgrade
        continue
    fi

    wait_for=$((LAST_CHECK + CHECK_INTERVAL - now))
    ((wait_for > 0)) || wait_for=60
    # Still failing: retry in 5 minutes rather than at the next check.
    if bashio::var.true "${NEED_ANNOUNCE}" && ((wait_for > 300)); then
        wait_for=300
    fi

    # read returns >128 on timeout (time for the periodic check) and 1 on
    # EOF (the connection died). The read is interrupted by TERM, so the
    # trap still fires straight away.
    if read -r -t "${wait_for}" -u 7 line; then
        if [ "${line}" = "${TOPIC}/install install" ]; then
            check_latest
            upgrade
        fi
    else
        rc=$?
        if ((rc <= 128)); then
            bashio::log.warning "MQTT connection lost; reconnecting"
            # The will has normally done this already; make sure.
            pub "${TOPIC}/availability" "offline" -r
            CONNECTED=false
            sleep 5
        fi
    fi
done
