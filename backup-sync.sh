#!/bin/sh
# backup-sync.sh — Copy backup archives from VM to host after deployment
# Card 76

# bash is trash and shell is hell
# i code under their cursed spell
# sometimes i feel a spark of hope
# of the variety called "cope"

############################
# Defaults
############################
VM_ARCHIVE_DIR="/var/tmp/bk/archives"
MAX_RETRIES=3
RETRY_DELAY=10
MODE="push"
CRON_MODE=0
LOG_FILE="/var/tmp/.log/backup-sync.log"
REMOTE_USER="root"
REMOTE_SSH_KEY=""
VERBOSE=0

############################
# Helpers
############################
usage() {
    printf "Usage: %s [OPTIONS] <VM_IP> <HOST_PATH>\n" "$0"
    printf "\n"
    printf "Sync backup archives between VM and host.\n"
    printf "\n"
    printf "Arguments:\n"
    printf "  VM_IP       IP address of the VM\n"
    printf "  HOST_PATH   Local directory to store synced backups\n"
    printf "\n"
    printf "Options:\n"
    printf "  --push           Push mode: VM copies archives to host (default)\n"
    printf "  --pull           Pull mode: host pulls archives from VM\n"
    printf "  --cron           Quiet mode for scheduled backups, logs to file\n"
    printf "  --user USER      Remote SSH user (default: root)\n"
    printf "  --key PATH       SSH private key path\n"
    printf "  --verbose        Show detailed output\n"
    printf "  --help           Show this help message\n"
    printf "\n"
    printf "Examples:\n"
    printf "  %s --push 192.168.1.100 /backups/quetzalcoatl\n" "$0"
    printf "  %s --pull 192.168.1.100 /backups/quetzalcoatl\n" "$0"
    printf "  %s --cron --push 192.168.1.100 /backups/quetzalcoatl\n" "$0"
    exit "${1:-0}"
}

log_msg() {
    if [ "$CRON_MODE" = "1" ]; then
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
    elif [ "$VERBOSE" = "1" ]; then
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
    fi
}

info() {
    if [ "$CRON_MODE" = "0" ]; then
        printf "== %s ==\n" "$1"
    fi
    log_msg "$1"
}

warn() {
    if [ "$CRON_MODE" = "0" ]; then
        printf "== WARNING: %s ==\n" "$1"
    fi
    log_msg "WARNING: $1"
}

error() {
    if [ "$CRON_MODE" = "0" ]; then
        printf "[ERROR] %s\n" "$1" >&2
    fi
    log_msg "ERROR: $1"
}

############################
# Retry wrapper
############################
retry_cmd() {
    cmd_desc="$1"
    shift
    attempt=1

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        if [ "$VERBOSE" = "1" ] && [ "$CRON_MODE" = "0" ]; then
            printf "Attempt %d/%d: %s\n" "$attempt" "$MAX_RETRIES" "$cmd_desc"
        fi
        log_msg "Attempt ${attempt}/${MAX_RETRIES}: ${cmd_desc}"

        "$@"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        warn "${cmd_desc} failed (exit ${rc}), retrying in ${RETRY_DELAY}s (attempt ${attempt}/${MAX_RETRIES})"

        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            sleep "$RETRY_DELAY"
        fi
        attempt=$((attempt + 1))
    done

    error "${cmd_desc} failed after ${MAX_RETRIES} attempts"
    return 1
}

############################
# SSH options builder
############################
ssh_opts() {
    opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
    if [ -n "$REMOTE_SSH_KEY" ]; then
        opts="$opts -i $REMOTE_SSH_KEY"
    fi
    printf "%s" "$opts"
}

############################
# Checksum verification
############################
generate_checksums() {
    dir="$1"
    output_file="$2"
    : > "$output_file"

    for archive in "$dir"/*.tar.gz; do
        [ -f "$archive" ] || continue
        sha256sum "$archive" >> "$output_file"
    done
}

verify_checksums() {
    checksum_file="$1"
    target_dir="$2"

    if [ ! -f "$checksum_file" ]; then
        error "Checksum file not found: $checksum_file"
        return 1
    fi

    failures=0
    while IFS='  ' read -r expected_hash filepath; do
        filename=$(basename "$filepath")
        target_file="$target_dir/$filename"

        if [ ! -f "$target_file" ]; then
            error "Missing file: $target_file"
            failures=$((failures + 1))
            continue
        fi

        actual_hash=$(sha256sum "$target_file" | cut -d' ' -f1)

        if [ "$expected_hash" != "$actual_hash" ]; then
            error "Checksum mismatch for $filename"
            log_msg "  Expected: $expected_hash"
            log_msg "  Actual:   $actual_hash"
            failures=$((failures + 1))
        else
            log_msg "  Verified: $filename"
        fi
    done < "$checksum_file"

    if [ "$failures" -gt 0 ]; then
        error "$failures file(s) failed checksum verification"
        return 1
    fi

    info "All checksums verified successfully"
    return 0
}

############################
# Push mode: VM → Host
############################
do_push() {
    vm_ip="$1"
    host_path="$2"
    timestamp=$(date '+%Y%m%d-%H%M%S')
    sync_dir="$host_path/sync-${timestamp}"

    info "Push mode: Syncing archives to ${REMOTE_USER}@${vm_ip}:${sync_dir}"

    # Create timestamped directory on host
    retry_cmd "create remote directory" ssh $(ssh_opts) "${REMOTE_USER}@${vm_ip}" \
        "mkdir -p '${sync_dir}'"
    if [ $? -ne 0 ]; then
        error "Failed to create remote directory"
        return 1
    fi

    # Generate checksums for source archives
    src_checksums="/tmp/backup-sync-checksums-${timestamp}.sha256"
    generate_checksums "$VM_ARCHIVE_DIR" "$src_checksums"

    archive_count=$(ls -1 "$VM_ARCHIVE_DIR"/*.tar.gz 2>/dev/null | wc -l)

    if [ "$archive_count" -eq 0 ]; then
        warn "No archives found in $VM_ARCHIVE_DIR"
        rm -f "$src_checksums"
        return 0
    fi

    info "Found $archive_count archive(s) to sync"

    # Transfer archives
    if command -v rsync > /dev/null; then
        retry_cmd "rsync transfer" rsync -avz --checksum \
            -e "ssh $(ssh_opts)" \
            "${VM_ARCHIVE_DIR}/" "${REMOTE_USER}@${vm_ip}:${sync_dir}/"
    else
        retry_cmd "scp transfer" scp $(ssh_opts) \
            "${VM_ARCHIVE_DIR}"/*.tar.gz "${REMOTE_USER}@${vm_ip}:${sync_dir}/"
    fi

    if [ $? -ne 0 ]; then
        error "Transfer failed"
        rm -f "$src_checksums"
        return 1
    fi

    # Transfer checksums
    retry_cmd "scp checksum file" scp $(ssh_opts) \
        "$src_checksums" "${REMOTE_USER}@${vm_ip}:${sync_dir}/checksums.sha256"

    # Verify checksums on host
    info "Verifying checksums on host..."
    retry_cmd "remote checksum verification" ssh $(ssh_opts) "${REMOTE_USER}@${vm_ip}" \
        "cd '${sync_dir}' && sha256sum -c checksums.sha256"

    if [ $? -ne 0 ]; then
        error "Remote checksum verification failed"
        rm -f "$src_checksums"
        return 1
    fi

    # Copy checksums to host for local records too
    retry_cmd "pull checksums locally" scp $(ssh_opts) \
        "${REMOTE_USER}@${vm_ip}:${sync_dir}/checksums.sha256" \
        "/tmp/backup-sync-verified-${timestamp}.sha256"

    rm -f "$src_checksums"

    info "Sync complete: ${REMOTE_USER}@${vm_ip}:${sync_dir}"
    info "Archives transferred: $archive_count"
    return 0
}

############################
# Pull mode: Host ← VM
############################
do_pull() {
    vm_ip="$1"
    host_path="$2"
    timestamp=$(date '+%Y%m%d-%H%M%S')
    sync_dir="$host_path/sync-${timestamp}"

    info "Pull mode: Pulling archives from ${REMOTE_USER}@${vm_ip}:${VM_ARCHIVE_DIR}"

    # Create local timestamped directory
    mkdir -p "$sync_dir"

    # Check if archives exist on VM
    remote_count=$(ssh $(ssh_opts) "${REMOTE_USER}@${vm_ip}" \
        "ls -1 ${VM_ARCHIVE_DIR}/*.tar.gz 2>/dev/null | wc -l")

    if [ "$remote_count" -eq 0 ]; then
        warn "No archives found on VM at ${VM_ARCHIVE_DIR}"
        rmdir "$sync_dir" 2>/dev/null
        return 0
    fi

    info "Found $remote_count archive(s) on VM"

    # Generate checksums on VM
    remote_checksum_file="checksums-${timestamp}.sha256"
    retry_cmd "generate remote checksums" ssh $(ssh_opts) "${REMOTE_USER}@${vm_ip}" \
        "cd ${VM_ARCHIVE_DIR} && sha256sum *.tar.gz > /tmp/${remote_checksum_file}"

    if [ $? -ne 0 ]; then
        error "Failed to generate remote checksums"
        rmdir "$sync_dir" 2>/dev/null
        return 1
    fi

    # Transfer archives
    if command -v rsync > /dev/null; then
        retry_cmd "rsync transfer" rsync -avz --checksum \
            -e "ssh $(ssh_opts)" \
            "${REMOTE_USER}@${vm_ip}:${VM_ARCHIVE_DIR}/" "${sync_dir}/"
    else
        retry_cmd "scp transfer" scp $(ssh_opts) \
            "${REMOTE_USER}@${vm_ip}:${VM_ARCHIVE_DIR}"/*.tar.gz "${sync_dir}/"
    fi

    if [ $? -ne 0 ]; then
        error "Transfer failed"
        rm -rf "$sync_dir"
        return 1
    fi

    # Transfer checksums
    retry_cmd "scp checksum file" scp $(ssh_opts) \
        "${REMOTE_USER}@${vm_ip}:/tmp/${remote_checksum_file}" \
        "${sync_dir}/checksums.sha256"

    # Verify checksums locally
    info "Verifying checksums locally..."
    verify_checksums "${sync_dir}/checksums.sha256" "$sync_dir"

    if [ $? -ne 0 ]; then
        error "Local checksum verification failed"
        return 1
    fi

    # Cleanup remote temp checksum file
    ssh $(ssh_opts) "${REMOTE_USER}@${vm_ip}" \
        "rm -f /tmp/${remote_checksum_file}" 2>/dev/null

    info "Sync complete: ${sync_dir}"
    info "Archives transferred: $remote_count"
    return 0
}

############################
# Argument parsing
############################
while [ $# -gt 0 ]; do
    case "$1" in
        --push)
            MODE="push"
            shift
            ;;
        --pull)
            MODE="pull"
            shift
            ;;
        --cron)
            CRON_MODE=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --user)
            REMOTE_USER="$2"
            shift 2
            ;;
        --key)
            REMOTE_SSH_KEY="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        -*)
            error "Unknown option: $1"
            usage 1
            ;;
        *)
            break
            ;;
    esac
done

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Require positional arguments
if [ $# -lt 2 ]; then
    error "Missing required arguments: <VM_IP> <HOST_PATH>"
    usage 1
fi

VM_IP="$1"
HOST_PATH="$2"

############################
# Ensure running as root
############################
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

# Make files created here private
umask 077

############################
# Pre-flight checks
############################
if [ "$MODE" = "push" ]; then
    if [ ! -d "$VM_ARCHIVE_DIR" ]; then
        error "Local archive directory not found: $VM_ARCHIVE_DIR"
        error "Run backup.sh first to create archives."
        exit 1
    fi

    if ! command -v ssh > /dev/null; then
        error "ssh is not installed"
        exit 1
    fi

    if ! command -v rsync > /dev/null && ! command -v scp > /dev/null; then
        error "Neither rsync nor scp is installed"
        exit 1
    fi
fi

if [ "$MODE" = "pull" ]; then
    if ! command -v ssh > /dev/null; then
        error "ssh is not installed"
        exit 1
    fi

    if ! command -v rsync > /dev/null && ! command -v scp > /dev/null; then
        error "Neither rsync nor scp is installed"
        exit 1
    fi

    mkdir -p "$HOST_PATH"
fi

############################
# Run sync
############################
if [ "$CRON_MODE" = "1" ]; then
    log_msg "========================================="
    log_msg "Backup sync started (cron mode)"
    log_msg "Mode: $MODE | VM: $VM_IP | Host path: $HOST_PATH"
    log_msg "========================================="
fi

if [ "$MODE" = "push" ]; then
    do_push "$VM_IP" "$HOST_PATH"
    exit_code=$?
elif [ "$MODE" = "pull" ]; then
    do_pull "$VM_IP" "$HOST_PATH"
    exit_code=$?
fi

if [ "$CRON_MODE" = "1" ]; then
    if [ "$exit_code" -eq 0 ]; then
        log_msg "Backup sync completed successfully"
    else
        log_msg "Backup sync FAILED with exit code $exit_code"
    fi
    log_msg "========================================="
fi

exit $exit_code
