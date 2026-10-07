#!/usr/bin/env bash
#
# Runs on the spot rebuilder, from user-data.
# Idempotent: a replacement re-attaches the volume
# and PERSIST resumes. No instance state.
#
# Env from the launch template:
#   VOLUME_ID        build volume (PERSIST state + outputs)
#   S3_BUCKET        our output bucket
#   UPSTREAM_URL     full URL, or our own key
#   UPSTREAM_REGION  boxes.10gen.com is eu-west-1
#   ASG_NAME         scaled to 0 on success
#   AWS_REGION       default us-west-2

set -euo pipefail

: "${VOLUME_ID:?}"
: "${S3_BUCKET:?}"
: "${UPSTREAM_URL:?}"
: "${UPSTREAM_REGION:=eu-west-1}"
: "${ASG_NAME:?}"
: "${AWS_REGION:=us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

MOUNT=/mnt/toolchain
LABEL=tcbuild
CHAINS="v4 v5"
RUN_LOG=/var/log/rebuild.log   # user_data tees our output here

log(){ echo "[rebuild $(date -u +%FT%TZ)] $*"; }

# ── toolchain id from the filename ──────────────────────────────────
# names vary; the 40-hex revision does not
UP_BASENAME=$(basename "$UPSTREAM_URL")
ID=$(grep -oE '[0-9a-f]{40}' <<<"$UP_BASENAME" | head -1)
[[ -n "$ID" ]] || { log "cannot parse 40-hex toolchain id from $UP_BASENAME"; exit 1; }
grep -q 'debian13' <<<"$UP_BASENAME" || log "WARN: $UP_BASENAME is not a debian13 tarball — building debian13 anyway"
REVISION="$ID"
log "toolchain id = $ID"

# ── IMDSv2 self identity ────────────────────────────────────────────
imds(){ local t; t=$(curl -sX PUT http://169.254.169.254/latest/api/token \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 300'); curl -s \
        -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(imds instance-id)

# ── keep the log after the instance dies ────────────────────────────
# a finished job takes its log along.
# Per-instance name keeps the predecessor's.
upload_log() {
    [[ -f "$RUN_LOG" ]] || return 0
    aws s3 cp --only-show-errors "$RUN_LOG" \
        "s3://$S3_BUCKET/logs/$ID/rebuild-${IID}.log" >/dev/null 2>&1 || true
}
# net for failures; success uploads earlier
trap 'rc=$?; upload_log; exit $rc' EXIT

# needs min_size 0; never fatal
scale_down() {
    if aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG_NAME" --desired-capacity 0; then
        log "requested ASG $ASG_NAME -> 0"
    else
        log "WARN: could not scale $ASG_NAME to 0 — instance stays up until torn down"
    fi
}

# ── published output is immutable ───────────────────────────────────
# .bzl files pin its sha256;
# a rebuild never matches byte for byte.
published() { aws s3 ls "s3://$S3_BUCKET/output/$ID/DONE" >/dev/null 2>&1; }
if published; then
    log "output/$ID/DONE exists — already published, not rebuilding"
    scale_down
    exit 0
fi

# ── attach + mount, also after a spot kill ──────────────────────────
if ! mountpoint -q "$MOUNT"; then
    state=$(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" \
            --query 'Volumes[0].Attachments[0].{iid:InstanceId,state:State}' --output json 2>/dev/null || echo '{}')
    other=$(jq -r '.iid // empty' <<<"$state")
    if [[ -n "$other" && "$other" != "$IID" ]]; then
        log "volume still attached to $other (dead spot) — force-detaching"
        aws ec2 detach-volume --volume-id "$VOLUME_ID" --force >/dev/null || true
        aws ec2 wait volume-available --volume-ids "$VOLUME_ID"
    fi
    if [[ "$other" != "$IID" ]]; then
        log "attaching $VOLUME_ID -> $IID"
        aws ec2 attach-volume --volume-id "$VOLUME_ID" --instance-id "$IID" --device /dev/sdf >/dev/null
    fi
    # Nitro renames /dev/sdf; match the EBS serial
    volser="vol${VOLUME_ID#vol-}"
    dev=""
    for _ in $(seq 1 30); do
        dev=$(readlink -f "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volser}" 2>/dev/null || true)
        [[ -b "$dev" ]] && break
        dev=""; sleep 3
    done
    [[ -b "$dev" ]] || { log "block device for $VOLUME_ID not found"; lsblk >&2; exit 1; }
    log "device = $dev"
    # first use only; otherwise keep the data
    if ! blkid "$dev" >/dev/null 2>&1; then
        log "no filesystem on $dev — mkfs ext4 (first use)"
        mkfs.ext4 -L "$LABEL" -F "$dev"
    fi
    mkdir -p "$MOUNT"
    mount "$dev" "$MOUNT"
fi
log "volume mounted at $MOUNT"

# ── swap: 32G, JOBS is aggressive ───────────────────────────────────
if ! swapon --show=NAME --noheadings | grep -q "$MOUNT/swapfile"; then
    if [[ ! -f "$MOUNT/swapfile" ]]; then
        fallocate -l 32G "$MOUNT/swapfile"; chmod 600 "$MOUNT/swapfile"; mkswap "$MOUNT/swapfile"
    fi
    swapon "$MOUNT/swapfile"
fi

# ── docker: build.sh compiles inside a container ─────────────────────
systemctl is-active --quiet docker || { command -v docker >/dev/null || { apt-get update -qq && apt-get install -y -qq docker.io; }; systemctl enable --now docker; }

# ── scripts are local and ephemeral; only state lives on the volume ──
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$SCRIPTS/build.sh" ]] || { log "build.sh not found next to $0"; exit 1; }

# ── fetch the upstream tarball ──────────────────────────────────────
# unsigned: our creds are another account's.
# Reference only, so failure just warns.
mkdir -p "$MOUNT/upstream"
up="$MOUNT/upstream/$UP_BASENAME"
if [[ ! -f "$up" ]]; then
    case "$UPSTREAM_URL" in
        s3://*)  aws s3 cp --only-show-errors --no-sign-request --region "$UPSTREAM_REGION" "$UPSTREAM_URL" "$up" || true ;;
        http*)   curl -fsSL "$UPSTREAM_URL" -o "$up" || true ;;
        *)       aws s3 cp --only-show-errors "s3://$S3_BUCKET/$UPSTREAM_URL" "$up" || true ;;  # key in our bucket
    esac
fi
[[ -f "$up" ]] || log "WARN: upstream $UPSTREAM_URL not fetched; continuing on pinned versions"
# TODO(introspect.sh): read versions from this archive's logs/

# ── build (resumes on rerun) ────────────────────────────────────────
JOBS=$(( $(nproc) * 3 / 2 ))
log "building debian13 chains '$CHAINS' with JOBS=$JOBS revision=$REVISION"
OUTPUT_DIR="$MOUNT/out" PERSIST=1 REVISION="$REVISION" JOBS="$JOBS" CHAINS="$CHAINS" \
    "$SCRIPTS/build.sh" debian13

# ── publish to our bucket ───────────────────────────────────────────
OUT="$MOUNT/out"
dst="s3://$S3_BUCKET/output/$ID"
published && { log "output/$ID/DONE appeared meanwhile — not overwriting"; scale_down; exit 0; }
# upstream's names with "-arm64" inserted
for art in "$OUT/bazel_v4_toolchain-debian13-arm64-${REVISION}.tar.gz" \
           "$OUT/bazel_v5_toolchain-debian13-arm64-${REVISION}.tar.gz" \
           "$OUT/bazel_v5_gdb-debian13-arm64-${REVISION}.tar.gz"; do
    [[ -f "$art" ]] || { log "MISSING $art"; exit 1; }
    aws s3 cp --only-show-errors "$art" "$dst/"
    aws s3 cp --only-show-errors "$art.sha256" "$dst/"
done

printf '%s ok id=%s\n' "$(date -u +%FT%TZ)" "$ID" | aws s3 cp - "$dst/DONE"
log "published to $dst ; DONE written"
log "log -> s3://$S3_BUCKET/logs/$ID/rebuild-${IID}.log"
upload_log

# ── done: scale the ASG to 0 (Jenkins also polls DONE) → instance terminates ──
scale_down
