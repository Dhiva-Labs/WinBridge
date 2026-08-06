#!/usr/bin/env bash
#
# winbridge-print.sh — ships a PDF to the WinBridge build VM and prints it
# there through a Windows-only (GDI) printer driver, via SumatraPDF's silent
# -print-to switch. See docs/devices.md for the full walkthrough (driverless
# IPP is almost always the better first option — read that before wiring this
# up) and docs/vm-setup.md for what the VM side needs.
#
# This is a plain bash script, not the Dart CLI, so it cannot read
# ~/.config/winbridge/vm.json directly — it takes the same fields as flags or
# environment variables instead, and validates every one of them against the
# same charsets VmConfig enforces in lib/src/vm/vm_config.dart. Keep the two
# in sync if either changes.
#
# Standalone:
#   winbridge-print.sh --host H --user U --identity KEY --workspace WS \
#       --printer NAME file.pdf
#   cat file.pdf | winbridge-print.sh --host H --user U --identity KEY \
#       --workspace WS --printer NAME
#
# As a CUPS System V filter: CUPS invokes filters positionally —
#   filter job-id user title copies options [file]
# — leaving no room for flags, so in that mode every connection value comes
# from the environment instead: WINBRIDGE_VM_HOST, WINBRIDGE_VM_USER,
# WINBRIDGE_VM_IDENTITY, WINBRIDGE_VM_WORKSPACE, WINBRIDGE_PRINTER, and
# optionally WINBRIDGE_VM_PORT / WINBRIDGE_SUMATRA_PATH. This mode is detected
# by the absence of any leading `--` flag. Values pulled from the environment
# are validated exactly as strictly as flags are — nothing gets a pass for
# arriving that way.
#
# The remote file name is never derived from the input file's name or from
# any CUPS job title — those are attacker-influenceable in principle, and the
# remote end really is a shell (Windows OpenSSH hands the command to cmd.exe).
# WinBridge generates its own token instead. See generate_remote_token below.

set -euo pipefail

script_name=$(basename "$0")

die() {
    printf '%s: %s\n' "$script_name" "$1" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $script_name --host H --user U [--port P] --identity KEY \\
           --workspace WS --printer NAME [--sumatra-path PATH] \\
           [--accept-new] [file.pdf]

Reads the PDF from the positional argument, or from stdin if omitted.
Every value may also come from the environment: WINBRIDGE_VM_HOST,
WINBRIDGE_VM_USER, WINBRIDGE_VM_PORT, WINBRIDGE_VM_IDENTITY,
WINBRIDGE_VM_WORKSPACE, WINBRIDGE_PRINTER, WINBRIDGE_SUMATRA_PATH.
See docs/devices.md.
EOF
    exit 2
}

# --- charsets, mirroring lib/src/vm/vm_config.dart -------------------------
host_pattern='^[A-Za-z0-9._-]+$'
user_pattern='^[A-Za-z0-9._-]+$'
workspace_pattern='^[A-Za-z0-9:/_.-]+$'
printer_pattern='^[A-Za-z0-9 ._-]+$'
port_pattern='^[0-9]+$'

validate() {
    # validate <value> <pattern> <field-name>
    local value="$1" pattern="$2" field="$3"
    if [[ ! "$value" =~ $pattern ]]; then
        die "invalid $field: \"$value\" (must match $pattern)"
    fi
}

# --- gather config: environment first, flags override ----------------------
host="${WINBRIDGE_VM_HOST:-}"
user="${WINBRIDGE_VM_USER:-}"
port="${WINBRIDGE_VM_PORT:-22}"
identity="${WINBRIDGE_VM_IDENTITY:-}"
workspace="${WINBRIDGE_VM_WORKSPACE:-}"
printer="${WINBRIDGE_PRINTER:-}"
sumatra_path="${WINBRIDGE_SUMATRA_PATH:-C:/tools/sumatra/SumatraPDF.exe}"
strict_host_key_checking=yes
pdf_file=""

if [[ $# -eq 0 ]]; then
    # Env-only mode: every value from the environment, PDF from stdin. Useful
    # when something else (a watcher, a cron job) already exported the
    # WINBRIDGE_* variables and just wants to pipe a file through.
    :
elif [[ "${1:-}" == --* || "${1:-}" == -h ]]; then
    # Flag mode.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host) host="$2"; shift 2 ;;
            --user) user="$2"; shift 2 ;;
            --port) port="$2"; shift 2 ;;
            --identity) identity="$2"; shift 2 ;;
            --workspace) workspace="$2"; shift 2 ;;
            --printer) printer="$2"; shift 2 ;;
            --sumatra-path) sumatra_path="$2"; shift 2 ;;
            --accept-new) strict_host_key_checking=accept-new; shift ;;
            -h|--help) usage ;;
            --) shift; break ;;
            --*) die "unknown flag: $1" ;;
            *) break ;;
        esac
    done
    if [[ $# -gt 1 ]]; then
        die "too many arguments: $*"
    fi
    pdf_file="${1:-}"
elif [[ $# -ge 5 && $# -le 6 ]]; then
    # CUPS System V filter mode: job-id user title copies options [file].
    # Everything winbridge-specific must already be in the environment.
    if [[ $# -eq 6 ]]; then
        pdf_file="$6"
    fi
else
    usage
fi

[[ -n "$host" ]] || die "missing host (--host or WINBRIDGE_VM_HOST)"
[[ -n "$user" ]] || die "missing user (--user or WINBRIDGE_VM_USER)"
[[ -n "$workspace" ]] || die "missing workspace (--workspace or WINBRIDGE_VM_WORKSPACE)"
[[ -n "$printer" ]] || die "missing printer (--printer or WINBRIDGE_PRINTER)"

validate "$host" "$host_pattern" host
validate "$user" "$user_pattern" user
validate "$port" "$port_pattern" port
if (( port < 1 || port > 65535 )); then
    die "invalid port: \"$port\" (must be between 1 and 65535)"
fi
validate "$workspace" "$workspace_pattern" workspace
if [[ "$workspace" == *..* ]]; then
    die "invalid workspace: \"$workspace\" (must not contain ..)"
fi
validate "$printer" "$printer_pattern" printer
validate "$sumatra_path" "$workspace_pattern" sumatra-path
if [[ "$sumatra_path" == *..* ]]; then
    die "invalid sumatra-path: \"$sumatra_path\" (must not contain ..)"
fi
if [[ -n "$identity" ]]; then
    [[ "$identity" != *[[:space:]]* ]] || die "identity path must not contain whitespace"
    [[ -r "$identity" ]] || die "identity file not readable: $identity"
fi

command -v ssh >/dev/null 2>&1 || die "ssh not found on PATH"
command -v scp >/dev/null 2>&1 || die "scp not found on PATH"

# --- resolve the PDF source: given file, or stdin into a temp file ---------
#
# cleanup's own exit status becomes the script's exit status once the EXIT
# trap runs — bash does not preserve whatever code the script was already
# exiting with — so this must end on a command that succeeds regardless of
# whether there was anything to remove. `[[ -n "$f" ]] && rm ...` would fail
# that requirement on an empty cleanup_files (the common, non-stdin case): the
# `&&` reports the condition's own false status as the loop's last exit code.
cleanup_files=()
cleanup() {
    local f
    for f in "${cleanup_files[@]:-}"; do
        if [[ -n "$f" ]]; then
            rm -f -- "$f"
        fi
    done
    return 0
}
trap cleanup EXIT

if [[ -n "$pdf_file" ]]; then
    [[ -r "$pdf_file" ]] || die "cannot read input file: $pdf_file"
    local_pdf="$pdf_file"
else
    local_pdf=$(mktemp --suffix .pdf)
    cleanup_files+=("$local_pdf")
    cat > "$local_pdf"
fi

# --- a remote file name that never comes from untrusted input --------------
# Neither the source file's name nor a CUPS job title is used here — both are
# in principle attacker-influenceable, and the remote end is a real shell.
# This token is digits only, generated entirely on this host.
generate_remote_token() {
    printf 'job%s%s' "$(date +%s)" "$$"
}
remote_token=$(generate_remote_token)
remote_dir="${workspace%/}/print"
remote_pdf="$remote_dir/$remote_token.pdf"

# --- ssh/scp options, mirroring OpenSshTransport ----------------------------
ssh_common_opts=(
    -o BatchMode=yes
    -o "StrictHostKeyChecking=$strict_host_key_checking"
    -o ConnectTimeout=10
)
if [[ -n "$identity" ]]; then
    ssh_common_opts+=(-i "$identity" -o IdentitiesOnly=yes)
fi

run_remote() {
    # run_remote <token> [<token> ...] — each token is one argv element to
    # ssh, exactly as lib/src/vm/remote_command.dart does it; ssh joins them
    # with a single space before handing the result to the VM's own shell.
    # Windows OpenSSH already runs whatever it receives through cmd.exe, so
    # none of these calls prefix a `cmd /c` of their own — doing that would
    # just nest a second cmd.exe inside the first for no reason.
    ssh -p "$port" "${ssh_common_opts[@]}" "$user@$host" "$@"
}

# quote_remote wraps a value in literal double quotes the way
# RemoteCommands._quote does in lib/src/vm/remote_command.dart, for a token
# that is about to become part of the command line cmd.exe parses.
quote_remote() {
    printf '"%s"' "$1"
}

remote_dir_q=$(quote_remote "$remote_dir")
remote_pdf_q=$(quote_remote "$remote_pdf")
sumatra_q=$(quote_remote "$sumatra_path")
printer_q=$(quote_remote "$printer")

# Best effort: the directory may already exist, in which case cmd.exe's mkdir
# fails and that failure is expected, not fatal.
run_remote if not exist "$remote_dir_q" mkdir "$remote_dir_q" || true

scp -P "$port" "${ssh_common_opts[@]}" "$local_pdf" "$user@$host:$remote_pdf" \
    || die "failed to copy $local_pdf to the vm"

# SumatraPDF's own quoting: the printer name and the path are each one
# quoted argv element built here, never handed to a shell locally. -silent
# suppresses SumatraPDF's own error dialogs, which would otherwise sit on the
# VM's desktop waiting for a click that this unattended path never sends.
if ! run_remote "$sumatra_q" -print-to "$printer_q" "$remote_pdf_q" -silent; then
    die "SumatraPDF failed on the vm (see docs/devices.md for setup)"
fi

# Best effort cleanup of the remote copy; a failure here does not fail the
# print job, which has already happened by this point.
run_remote del "$remote_pdf_q" || true

printf '%s: printed %s to "%s" via %s@%s\n' "$script_name" "$local_pdf" "$printer" "$user" "$host"
