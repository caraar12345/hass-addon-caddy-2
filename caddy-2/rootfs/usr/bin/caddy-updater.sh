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
    local before after old_modules new_modules
    before=$(installed_version)
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

shutdown() {
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
announce
bashio::log.info "Caddy update entity published: installed $(installed_version), latest ${LATEST_VERSION:-unknown}"

while true; do
    now=$(date +%s)
    if ((now - LAST_CHECK >= CHECK_INTERVAL)); then
        check_latest
        NEED_ANNOUNCE=true
    fi
    if bashio::var.true "${NEED_ANNOUNCE}"; then
        announce
    fi
    wait_for=$((LAST_CHECK + CHECK_INTERVAL - now))
    ((wait_for > 0)) || wait_for=60

    # A persistent QoS 1 session (-c) queues an Install pressed between
    # subscriptions. -W returns (exit 27) when nothing arrives in time.
    # The will marks the entity unavailable if the container dies mid-wait.
    # Run in the background so the TERM trap fires straight away.
    mosquitto_sub "${MQTT_ARGS[@]}" -i "${CLIENT_ID}-sub" -c -q 1 -C 1 -W "${wait_for}" \
        --will-topic "${TOPIC}/availability" --will-payload offline --will-retain --will-qos 1 \
        -t "${TOPIC}/install" > /tmp/caddy-updater-cmd &
    rc=0
    wait $! || rc=$?
    if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 27 ]; then
        bashio::log.warning "MQTT subscribe failed (exit ${rc}); retrying in 60s"
        NEED_ANNOUNCE=true
        sleep 60
        continue
    fi

    if [ "$(cat /tmp/caddy-updater-cmd 2>/dev/null)" = "install" ]; then
        : > /tmp/caddy-updater-cmd
        check_latest
        upgrade
    fi
done
