#!/bin/sh
# =============================================================================
#  esxi-patch.sh -- Interactive ESXi Patch Utility
#  Run on ESXi host shell via SSH from a Windows VM on the same host.
#
#  Pull and run:
#    wget -O /tmp/esxi-patch.sh "https://your-host/esxi-patch.sh" && sh /tmp/esxi-patch.sh
#    curl -o /tmp/esxi-patch.sh "https://your-host/esxi-patch.sh" && sh /tmp/esxi-patch.sh
#
#  What happens to your management VM:
#    - A graceful guest shutdown is sent before the host reboots.
#    - Your SSH session drops as the VM shuts down -- that's expected.
#    - The patch and reboot continue in a background process on the host.
#    - The VM auto-starts when the host comes back up (already configured).
#    - Reconnect after the host comes back up.
# =============================================================================

SEP="========================================================================"
SEP_S="------------------------------------------------------------------------"
LOG_FILE="/tmp/esxi-patch-$(date +%Y%m%d-%H%M%S).log"
EXEC_SCRIPT="/tmp/esxi_patch_exec.sh"

# ------------------------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------------------------

log()    { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
info()   { log "INFO  $*"; }
ok()     { log "OK    $*"; }
warn()   { log "WARN  $*"; }
fail()   {
    log "FAIL  $*"
    log "Aborted -- no changes made to the host."
    log "Log: $LOG_FILE"
    exit 1
}
sep()    { log "$SEP"; }
seps()   { log "$SEP_S"; }
pf_ok()  { printf "  [PASS] %s\n" "$*" | tee -a "$LOG_FILE"; }
pf_warn(){ printf "  [WARN] %s\n" "$*" | tee -a "$LOG_FILE"; }
pf_fail(){ printf "  [FAIL] %s\n" "$*" | tee -a "$LOG_FILE"; PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS+1)); }

# ------------------------------------------------------------------------------
# HEADER
# ------------------------------------------------------------------------------

clear
printf "\n%s\n" "$SEP"
printf "  ESXi Interactive Patch Utility\n"
printf "  Log: %s\n" "$LOG_FILE"
printf "%s\n\n" "$SEP"

sep
info "Session started"
seps

# ------------------------------------------------------------------------------
# PREFLIGHT CHECKS
# ------------------------------------------------------------------------------

printf "\n  Running preflight checks...\n\n"

PREFLIGHT_ERRORS=0

# Root
if [ "$(id -u)" -ne 0 ]; then
    pf_fail "Not running as root"
    fail "Re-run as root."
fi
pf_ok "Running as root"

# ESXi
if ! command -v esxcli > /dev/null 2>&1; then
    pf_fail "esxcli not found -- must run on an ESXi host shell"
    fail "Not an ESXi host."
fi
pf_ok "esxcli available"

# vim-cmd
if ! command -v vim-cmd > /dev/null 2>&1; then
    pf_fail "vim-cmd not found"
    fail "vim-cmd is required for VM management."
fi
pf_ok "vim-cmd available"

# Host info
HOSTNAME=$(esxcli system hostname get 2>/dev/null | awk '/Fully Qualified/ {print $NF}')
VERSION=$(esxcli system version get 2>/dev/null | awk '/Version/ {print $3}')
BUILD=$(esxcli system version get 2>/dev/null | awk '/Build/ {print $2}')
pf_ok "Host: ${HOSTNAME:-unknown}  |  ESXi ${VERSION:-?}  build ${BUILD:-?}"

# nohup
if ! command -v nohup > /dev/null 2>&1; then
    pf_fail "nohup not found -- patch cannot safely survive SSH disconnect"
    fail "nohup is required."
fi
pf_ok "nohup available"

# Maintenance mode
MM_STATE=$(esxcli system maintenanceMode get 2>/dev/null)
if [ "$MM_STATE" = "Enabled" ]; then
    pf_warn "Host is already in maintenance mode"
else
    pf_ok "Maintenance mode currently disabled"
fi

# Datastores
if [ ! -d "/vmfs/volumes" ] || [ -z "$(ls /vmfs/volumes 2>/dev/null)" ]; then
    pf_fail "/vmfs/volumes empty or not mounted"
    fail "No datastores available."
fi
DS_COUNT=0
for p in /vmfs/volumes/*; do [ -L "$p" ] && DS_COUNT=$((DS_COUNT+1)); done
[ "$DS_COUNT" -eq 0 ] && fail "No named datastores found."
pf_ok "$DS_COUNT named datastore(s) available"

# rc.local.d
RC_LOCAL_OK=0
if [ -w "/etc/rc.local.d/local.sh" ]; then
    pf_ok "/etc/rc.local.d/local.sh writable"
    RC_LOCAL_OK=1
else
    pf_warn "/etc/rc.local.d/local.sh not writable -- auto-exit maintenance mode unavailable"
fi

# Scratch space
SCRATCH_FREE=$(df /scratch 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$SCRATCH_FREE" ] && [ "$SCRATCH_FREE" -lt 204800 ]; then
    pf_warn "Scratch space low (${SCRATCH_FREE}KB) -- VIB staging may fail"
else
    pf_ok "Scratch space OK (${SCRATCH_FREE:-unknown}KB free)"
fi

printf "\n"
[ "$PREFLIGHT_ERRORS" -gt 0 ] && fail "$PREFLIGHT_ERRORS preflight check(s) failed."
info "All preflight checks passed"
seps

# ------------------------------------------------------------------------------
# SELECT DATASTORE
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 1/5 -- Select Datastore\n"
printf "%s\n\n" "$SEP_S"

IDX=0
for path in /vmfs/volumes/*; do
    [ -L "$path" ] || continue
    IDX=$((IDX+1))
    NAME=$(basename "$path")
    FREE=$(df "$path" 2>/dev/null | awk 'NR==2 {printf "%.0fGB free", $4/1048576}')
    printf "  [%d] %-30s %s\n" "$IDX" "$NAME" "${FREE}"
    eval "DSNAME_${IDX}=${NAME}"
done
DS_TOTAL=$IDX

printf "\n  Select [1-%d]: " "$DS_TOTAL"
read DS_IDX
case "$DS_IDX" in ''|*[!0-9]*) fail "Invalid input." ;; esac
[ "$DS_IDX" -lt 1 ] || [ "$DS_IDX" -gt "$DS_TOTAL" ] && fail "Out of range."

eval "SELECTED_DS=\$DSNAME_${DS_IDX}"
DS_PATH="/vmfs/volumes/${SELECTED_DS}"
PATCH_DIR="${DS_PATH}/patch"
info "Datastore: $SELECTED_DS"

[ -d "$PATCH_DIR" ] || fail "/patch directory not found at ${PATCH_DIR}"

# ------------------------------------------------------------------------------
# SELECT PATCH FILE
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 2/5 -- Select Patch File  (%s/patch/)\n" "$SELECTED_DS"
printf "%s\n\n" "$SEP_S"

IDX=0
for f in "${PATCH_DIR}"/*.zip "${PATCH_DIR}"/*.ZIP \
          "${PATCH_DIR}"/*.vib "${PATCH_DIR}"/*.VIB; do
    [ -e "$f" ] || continue
    IDX=$((IDX+1))
    FNAME=$(basename "$f")
    FSIZE=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
    printf "  [%d] %-50s %s\n" "$IDX" "$FNAME" "${FSIZE}"
    eval "FILENAME_${IDX}=${FNAME}"
done
FILE_TOTAL=$IDX

[ "$FILE_TOTAL" -eq 0 ] && fail "No .zip or .vib files found in ${PATCH_DIR}"

printf "\n  Select [1-%d]: " "$FILE_TOTAL"
read FILE_IDX
case "$FILE_IDX" in ''|*[!0-9]*) fail "Invalid input." ;; esac
[ "$FILE_IDX" -lt 1 ] || [ "$FILE_IDX" -gt "$FILE_TOTAL" ] && fail "Out of range."

eval "SELECTED_FILE=\$FILENAME_${FILE_IDX}"
DEPOT_PATH="${PATCH_DIR}/${SELECTED_FILE}"
[ -r "$DEPOT_PATH" ] || fail "Cannot read: $DEPOT_PATH"

case "$SELECTED_FILE" in
    *.zip|*.ZIP) DEPOT_FLAG="-d" ;;
    *.vib|*.VIB) DEPOT_FLAG="-v" ;;
    *)           DEPOT_FLAG="-d" ; warn "Unknown extension, assuming depot (-d)" ;;
esac

info "Patch file: $SELECTED_FILE"

# ------------------------------------------------------------------------------
# VIB COMMAND
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 3/5 -- VIB Command\n"
printf "%s\n\n" "$SEP_S"
printf "  [1] update   Install only if newer version available (recommended)\n"
printf "  [2] install  Force install regardless of version\n"
printf "\n  Select [1-2] (default 1): "
read VIB_IDX
case "$VIB_IDX" in
    2) VIB_CMD="install" ;;
    *) VIB_CMD="update"  ;;
esac
info "VIB command: $VIB_CMD"

# ------------------------------------------------------------------------------
# SELECT MANAGEMENT VM
# Only used to send a graceful shutdown before reboot.
# Auto-start is already configured -- we don't touch it.
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 4/5 -- Select Your Management VM\n"
printf "\n  This VM will receive a graceful shutdown signal before the host\n"
printf "  reboots. Auto-start is already configured so it comes back on its own.\n"
printf "%s\n\n" "$SEP_S"

IDX=0
while IFS= read -r line; do
    VMID=$(printf "%s" "$line" | awk '{print $1}')
    VMNAME=$(printf "%s" "$line" | awk '{print $2}')
    GUESTOS=$(printf "%s" "$line" | awk '{print $4}')
    [ -z "$VMID" ] && continue
    IDX=$((IDX+1))
    printf "  [%d] %-35s %-30s (VMID: %s)\n" "$IDX" "$VMNAME" "$GUESTOS" "$VMID"
    eval "VMID_${IDX}=${VMID}"
    eval "VMNAME_${IDX}=${VMNAME}"
done << VMLIST
$(vim-cmd vmsvc/getallvms 2>/dev/null | tail -n +2)
VMLIST
VM_TOTAL=$IDX

MGMT_VMID=""
MGMT_VMNAME="(none)"

if [ "$VM_TOTAL" -eq 0 ]; then
    warn "No VMs found -- skipping shutdown step"
else
    printf "\n  Your management VM [1-%d]: " "$VM_TOTAL"
    read VM_IDX
    case "$VM_IDX" in ''|*[!0-9]*) fail "Invalid input." ;; esac
    [ "$VM_IDX" -lt 1 ] || [ "$VM_IDX" -gt "$VM_TOTAL" ] && fail "Out of range."

    eval "MGMT_VMID=\$VMID_${VM_IDX}"
    eval "MGMT_VMNAME=\$VMNAME_${VM_IDX}"
    info "Management VM: $MGMT_VMNAME (VMID $MGMT_VMID)"

    VM_STATE=$(vim-cmd vmsvc/power.getstate "$MGMT_VMID" 2>/dev/null | tail -1)
    printf "%s" "$VM_STATE" | grep -qi "on" \
        || warn "VM does not appear to be powered on (state: ${VM_STATE})"
fi

# ------------------------------------------------------------------------------
# AUTO-EXIT MAINTENANCE MODE
# ------------------------------------------------------------------------------

AUTO_EXIT_MM=0
if [ "$RC_LOCAL_OK" -eq 1 ]; then
    printf "\n%s\n" "$SEP_S"
    printf "  Step 5/5 -- Post-Reboot Maintenance Mode\n"
    printf "%s\n\n" "$SEP_S"
    printf "  After rebooting, the host stays in maintenance mode until cleared.\n"
    printf "  Auto-exit maintenance mode on first boot? [y/N]: "
    read AUTO_EXIT_REPLY
    case "$AUTO_EXIT_REPLY" in
        y|Y|yes|YES) AUTO_EXIT_MM=1 ; info "Auto-exit MM: yes" ;;
        *)           info "Auto-exit MM: no (manual)" ;;
    esac
fi

# ------------------------------------------------------------------------------
# SUMMARY + CONFIRM
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP"
printf "  Summary\n"
printf "%s\n" "$SEP"
printf "  Host          : %s  (ESXi %s build %s)\n" "${HOSTNAME:-unknown}" "${VERSION:-?}" "${BUILD:-?}"
printf "  Datastore     : %s\n" "$SELECTED_DS"
printf "  Patch file    : %s\n" "$SELECTED_FILE"
printf "  Command       : esxcli software vib %s %s\n" "$VIB_CMD" "$DEPOT_FLAG"
printf "  Management VM : %s\n" "$MGMT_VMNAME"
printf "  Auto-exit MM  : %s\n" "$([ $AUTO_EXIT_MM -eq 1 ] && printf yes || printf no)"
printf "\n  Sequence:\n"
printf "    1. Enter maintenance mode\n"
printf "    2. Hand off to background process\n"
printf "    3. Gracefully shut down '%s'  <-- your session drops here\n" "$MGMT_VMNAME"
printf "    4. Apply patch\n"
printf "    5. Reboot host\n"
[ "$AUTO_EXIT_MM" -eq 1 ] && \
printf "    6. Exit maintenance mode automatically on first boot\n"
printf "\n  Your VM is already on auto-start and will come back on its own.\n"
printf "  Reconnect to %s after the host is back up.\n" "${HOSTNAME:-the host}"
printf "\n%s\n\n" "$SEP"

printf "  Proceed? [y/N]: "
read CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) printf "\nAborted. No changes made.\n\n"; exit 0 ;;
esac

sep
info "User confirmed -- beginning patch sequence"
seps

# ------------------------------------------------------------------------------
# AUTO-EXIT MM HOOK
# ------------------------------------------------------------------------------

if [ "$AUTO_EXIT_MM" -eq 1 ]; then
    info "Writing auto-exit MM hook to /etc/rc.local.d/local.sh"
    sed -i '/ESXI_PATCH_EXIT_MM/d' /etc/rc.local.d/local.sh 2>/dev/null
    sed -i '/maintenanceMode set --enable false/d' /etc/rc.local.d/local.sh 2>/dev/null
    cat >> /etc/rc.local.d/local.sh << 'RC_EOF'

# ESXI_PATCH_EXIT_MM -- written by esxi-patch.sh, self-removes after one boot
esxcli system maintenanceMode set --enable false
sed -i '/ESXI_PATCH_EXIT_MM/d' /etc/rc.local.d/local.sh
sed -i '/maintenanceMode set --enable false/d' /etc/rc.local.d/local.sh
RC_EOF
    grep -q "ESXI_PATCH_EXIT_MM" /etc/rc.local.d/local.sh \
        && ok "Auto-exit MM hook written" \
        || warn "Hook may not have written correctly -- check /etc/rc.local.d/local.sh"
fi

# ------------------------------------------------------------------------------
# ENTER MAINTENANCE MODE
# ------------------------------------------------------------------------------

info "[1/3] Entering maintenance mode..."
esxcli system maintenanceMode set --enable true

WAITED=0
while [ "$(esxcli system maintenanceMode get 2>/dev/null)" != "Enabled" ]; do
    sleep 5
    WAITED=$((WAITED+5))
    info "      Waiting... (${WAITED}s)"
    if [ "$WAITED" -ge 120 ]; then
        [ "$AUTO_EXIT_MM" -eq 1 ] && {
            sed -i '/ESXI_PATCH_EXIT_MM/d' /etc/rc.local.d/local.sh
            sed -i '/maintenanceMode set --enable false/d' /etc/rc.local.d/local.sh
        }
        fail "Timed out waiting for maintenance mode."
    fi
done
ok "[1/3] Maintenance mode active"

# ------------------------------------------------------------------------------
# BUILD BACKGROUND EXEC SCRIPT + LAUNCH
# ------------------------------------------------------------------------------

info "Writing background execution script..."

cat > "$EXEC_SCRIPT" << EXECEOF
#!/bin/sh
LOG_FILE="${LOG_FILE}"
MGMT_VMID="${MGMT_VMID}"
MGMT_VMNAME="${MGMT_VMNAME}"
DEPOT_PATH="${DEPOT_PATH}"
VIB_CMD="${VIB_CMD}"
DEPOT_FLAG="${DEPOT_FLAG}"

log() { printf "[%s] %s\n" "\$(date '+%H:%M:%S')" "\$*" >> "\$LOG_FILE"; }
info() { log "INFO  \$*"; }
ok()   { log "OK    \$*"; }
warn() { log "WARN  \$*"; }

info "========================================================"
info "Background exec started (PID \$\$)"
info "========================================================"

# -- Graceful VM shutdown --
if [ -n "\$MGMT_VMID" ]; then
    info "[2/3] Sending graceful shutdown to '\${MGMT_VMNAME}' (VMID \${MGMT_VMID})"
    VM_STATE=\$(vim-cmd vmsvc/power.getstate "\$MGMT_VMID" 2>/dev/null | tail -1)

    if printf "%s" "\$VM_STATE" | grep -qi "on"; then
        vim-cmd vmsvc/power.shutdown "\$MGMT_VMID" >> "\$LOG_FILE" 2>&1
        info "      Shutdown signal sent -- waiting up to 90s..."

        WAITED=0
        while [ \$WAITED -lt 90 ]; do
            sleep 5
            WAITED=\$((WAITED+5))
            STATE=\$(vim-cmd vmsvc/power.getstate "\$MGMT_VMID" 2>/dev/null | tail -1)
            info "      State: \${STATE}  (\${WAITED}s)"
            printf "%s" "\$STATE" | grep -qi "off" && { ok "      VM powered off cleanly"; break; }
        done

        # Force off if still running
        STATE=\$(vim-cmd vmsvc/power.getstate "\$MGMT_VMID" 2>/dev/null | tail -1)
        if ! printf "%s" "\$STATE" | grep -qi "off"; then
            warn "      Graceful shutdown timed out -- forcing power off"
            vim-cmd vmsvc/power.off "\$MGMT_VMID" >> "\$LOG_FILE" 2>&1
            sleep 5
        fi
    else
        warn "      VM not powered on (state: \${VM_STATE}) -- skipping"
    fi
else
    info "[2/3] No management VM selected -- skipping shutdown"
fi

# -- Apply patch --
info "[3/3] Applying patch..."
info "      esxcli software vib \${VIB_CMD} \${DEPOT_FLAG} \${DEPOT_PATH}"

esxcli software vib "\$VIB_CMD" "\$DEPOT_FLAG" "\$DEPOT_PATH" >> "\$LOG_FILE" 2>&1
PATCH_RC=\$?

if [ \$PATCH_RC -ne 0 ]; then
    if tail -5 "\$LOG_FILE" | grep -qi "no update\|already installed\|downgrade"; then
        warn "Patch appears to already be applied -- rebooting anyway"
    else
        warn "Patch FAILED (exit code \$PATCH_RC) -- aborting reboot"
        warn "Exiting maintenance mode. Reconnect and check: \$LOG_FILE"
        esxcli system maintenanceMode set --enable false
        sed -i '/ESXI_PATCH_EXIT_MM/d' /etc/rc.local.d/local.sh 2>/dev/null
        sed -i '/maintenanceMode set --enable false/d' /etc/rc.local.d/local.sh 2>/dev/null
        exit 1
    fi
fi

ok "Patch applied -- rebooting in 5 seconds"
sleep 5
reboot
EXECEOF

chmod +x "$EXEC_SCRIPT"
ok "Execution script ready"

nohup sh "$EXEC_SCRIPT" >> "$LOG_FILE" 2>&1 &
EXEC_PID=$!
ok "Background process launched (PID $EXEC_PID)"
seps

# ------------------------------------------------------------------------------
# DONE -- hand off complete
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP"
printf "  Handed off to background process (PID %s)\n\n" "$EXEC_PID"
printf "  What happens next:\n"
printf "    - '%s' will be shut down gracefully\n" "$MGMT_VMNAME"
printf "    - Your SSH session will disconnect\n"
printf "    - Patch will be applied and host will reboot\n"
printf "    - Your VM auto-starts when the host comes back up\n"
printf "\n  Check the log after reconnecting:\n"
printf "    cat %s\n" "$LOG_FILE"
printf "%s\n\n" "$SEP"

exit 0