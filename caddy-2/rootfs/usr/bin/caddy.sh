#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant App: Caddy 2
#
# Launch Caddy
# ------------------------------------------------------------------------------
 

# Prepare Caddy function to set custom Caddy path and check for custom Caddy 
# binary at the specified path. If found, exports custom Caddy variables;
# otherwise, uses the built-in Caddy binary path.
# Finally, checks the Caddy version.
prepare_secrets() {
    bashio::log.info 'Preparing secrets...'

    local secrets_file="/share/caddy/secrets.yaml.age"
    local identity

    if ! bashio::config.has_value 'age_identity'; then
        bashio::log.info "No age_identity configured, skipping secrets"
        return 0
    fi

    identity=$(bashio::config 'age_identity')

    if ! bashio::fs.file_exists "${secrets_file}"; then
        bashio::log.info "No secrets.yaml.age found at ${secrets_file}, skipping"
        return 0
    fi

    bashio::log.info "Decrypting ${secrets_file}..."

    local decrypted
    if ! decrypted=$(age --decrypt -i <(printf '%s' "${identity}") "${secrets_file}"); then
        bashio::log.error "Failed to decrypt ${secrets_file}"
        return 1
    fi

    mkdir -p /run/secrets
    chmod 700 /run/secrets

    while IFS='=' read -r name value; do
        [[ -z "${name}" ]] && continue
        bashio::log.info "Writing secret: ${name}"
        printf '%s' "${value}" > "/run/secrets/${name}"
        chmod 600 "/run/secrets/${name}"
    done < <(python3 -c "
import yaml, sys
data = yaml.safe_load(sys.stdin)
for k, v in data.items():
    print(f'{k}={v}')
" <<< "${decrypted}")

    bashio::log.info "Secrets written to /run/secrets/"
}

prepare_caddy() {
    bashio::log.info 'Prepare Caddy...'

    # Set custom Caddy path
    CUSTOM_CADDY_PATH="/config/caddy"

    # Check for custom Caddy binary at custom Caddy path
    bashio::log.info "Checking path: ${CUSTOM_CADDY_PATH}"
    if bashio::fs.file_exists "${CUSTOM_CADDY_PATH}"; then
        bashio::log.info "Found custom Caddy binary at ${CUSTOM_CADDY_PATH}"
        bashio::log.info "Custom Caddy has following modules installed:"
        "${CUSTOM_CADDY_PATH}" list-modules -s
        export CUSTOM_CADDY=true
        export CADDY_PATH="${CUSTOM_CADDY_PATH}"
    else
        bashio::log.info "Use built-in Caddy"
        export CUSTOM_CADDY=false
        export CADDY_PATH="/usr/bin/caddy"
    fi

    # Check caddy version
    "${CADDY_PATH}" version
}

# Upgrade Caddy function to upgrade Caddy to the latest version
caddy_upgrade() {
    bashio::log.info 'Upgrade Caddy...'

    if ! ${CUSTOM_CADDY}; then
        bashio::log.info "Cannot upgrade Caddy as no custom binary has been found"
        return 0
    fi

    local latest
    latest=$(curl -sL https://api.github.com/repos/caddyserver/caddy/releases/latest | jq -r '.tag_name')
    if [ "$(${CADDY_PATH} version | awk '{print $1}')" == "${latest}" ]; then
        bashio::log.info "Custom Caddy uses the latest version"
        return 0
    fi

    # Don't keep reinstalling a release verify_upgraded_caddy already rolled back.
    if bashio::fs.file_exists "${CUSTOM_CADDY_PATH}.rejected" \
        && [ "$("${CUSTOM_CADDY_PATH}.rejected" version 2>/dev/null | awk '{print $1}')" == "${latest}" ]; then
        bashio::log.warning "Not upgrading to ${latest}: it rejected the config before (${CUSTOM_CADDY_PATH}.rejected)"
        return 0
    fi

    bashio::log.info "Initiate upgrade"
    # Same safety net as the update entity: keep the previous binary and have
    # verify_upgraded_caddy check the new one against the config.
    cp -p "${CUSTOM_CADDY_PATH}" "${CUSTOM_CADDY_PATH}.bak"
    if "${CADDY_PATH}" upgrade && ! cmp -s "${CUSTOM_CADDY_PATH}" "${CUSTOM_CADDY_PATH}.bak"; then
        touch "${CUSTOM_CADDY_PATH}.upgraded"
    fi
}

prepare_caddyfile() {
    bashio::log.info 'Prepare Caddyfile...'

    # Set custom Caddyfile path
    CUSTOM_CADDYFILE_PATH="/config/Caddyfile"
    
    # Check for existing Caddyfile
    if bashio::fs.file_exists "${CUSTOM_CADDYFILE_PATH}"; then
        bashio::log.info "Caddyfile found at ${CUSTOM_CADDYFILE_PATH}"
        export CONFIG_PATH=${CUSTOM_CADDYFILE_PATH}
        export CADDYFILE=true
    else
        bashio::log.info "No Caddyfile found"
        bashio::log.info "Use non_caddyfile_config"
        export CONFIG_PATH=/etc/caddy/Caddyfile
        export CADDYFILE=false

        non_caddyfile_config
    fi
}

non_caddyfile_config() {
    bashio::log.trace "${FUNCNAME[0]}"

    EMAIL=$(bashio::config 'non_caddyfile_config.email')
    DOMAIN=$(bashio::config 'non_caddyfile_config.domain')
    DESTINATION=$(bashio::config 'non_caddyfile_config.destination')
    PORT=$(bashio::config 'non_caddyfile_config.port')
    
    export EMAIL
    export DOMAIN
    export DESTINATION
    export PORT
}

# After the update entity upgrades the custom binary, check that it can load
# the active config before running it. If it can't but the previous binary
# can, go back to the previous one rather than fail to start.
verify_upgraded_caddy() {
    local marker="${CUSTOM_CADDY_PATH}.upgraded" backup="${CUSTOM_CADDY_PATH}.bak"

    bashio::fs.file_exists "${marker}" || return 0
    rm -f "${marker}"
    ${CUSTOM_CADDY} || return 0

    # Validate the same config `run` gets: pass on the config-related
    # options from args, but not run-only ones.
    local -a validate_args=(--config "${CONFIG_PATH}")
    local i=0
    while ((i < ${#args[@]})); do
        case "${args[i]}" in
            --adapter|--envfile)
                validate_args+=("${args[i]}" "${args[i + 1]:-}")
                i=$((i + 1))
                ;;
            --adapter=*|--envfile=*)
                validate_args+=("${args[i]}")
                ;;
        esac
        i=$((i + 1))
    done

    bashio::log.info "Caddy was just upgraded; validating the config with the new binary..."
    if "${CADDY_PATH}" validate "${validate_args[@]}"; then
        bashio::log.info "The upgraded Caddy accepts the config"
        return 0
    fi

    if bashio::fs.file_exists "${backup}" && "${backup}" validate "${validate_args[@]}" > /dev/null 2>&1; then
        bashio::log.error "The upgraded Caddy rejects the config but the previous binary accepts it; restoring ${backup}"
        cp -p "${CUSTOM_CADDY_PATH}" "${CUSTOM_CADDY_PATH}.rejected"
        cp -p "${backup}" "${CUSTOM_CADDY_PATH}"
        "${CADDY_PATH}" version
    else
        bashio::log.warning "The config doesn't validate with the previous binary either, so keeping the upgraded one"
    fi
}

caddy_fmt() {
    bashio::log.info 'Format Caddyfile...'

    if ! ${CADDYFILE}; then
        bashio::log.info "No Caddyfile found"
        return 0
    fi

    if [ -w ${CONFIG_PATH} ]; then
        bashio::log.info "Overwrite Caddyfile"
        "${CADDY_PATH}" fmt --overwrite ${CONFIG_PATH}
    else
        bashio::log.info "Caddyfile has been found but is not writable"
    fi
}

main() {
    bashio::log.trace "${FUNCNAME[0]}"

    declare name
    declare value
    declare -a args=()

    # Load command line arguments
    for arg in $(bashio::config 'args|keys'); do
        # shellcheck disable=SC2207
        args+=( $(bashio::config "args[${arg}]") )
    done

    # Load custom environment variables
    for var in $(bashio::config 'env_vars|keys'); do
        name=$(bashio::config "env_vars[${var}].name")
        value=$(bashio::config "env_vars[${var}].value")
        bashio::log.info "Setting ${name} to ${value}"
        export "${name}=${value}"
    done

    # Install custom Python packages
    for package in $(bashio::config 'python_packages'); do
        bashio::log.info "Installing Python package ${package}"
        python3 -m pip install ${package}
    done

    # Format Caddyfile
    # bashio::log.info "Format Caddyfile"
    # "${CADDY_PATH}" fmt "${CONFIG_PATH}"

    # Decrypt and prepare secrets
    prepare_secrets

    # Prepare Caddy
    prepare_caddy

    # Upgrade Caddy
    if bashio::config.true 'caddy_upgrade'; then
        caddy_upgrade
    fi

    # Prepare Caddyfile
    prepare_caddyfile

    # Check a binary the update entity just upgraded
    verify_upgraded_caddy

    # Format Caddyfile
    if bashio::config.true 'caddy_fmt'; then
        caddy_fmt
    fi

    # Run Caddy
    bashio::log.info "Run Caddy..."
    bashio::log.debug "'${CADDY_PATH}' run --config '${CONFIG_PATH}' '${args[*]}'"
    "${CADDY_PATH}" run --config "${CONFIG_PATH}" "${args[@]}"
}
main "$@"
