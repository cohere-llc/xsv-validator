#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# xsv-validate.sh — Normalize and validate a TSV/CSV file using qsv
#
# Usage:
#   ./xsv-validate.sh <input_file> -s <schema.json> -o <output_folder> [options]
#
# Arguments:
#   <input_file>       Path to the CSV or TSV file to validate
#
# Options:
#   --comment CHAR     Comment character to strip (default: #)
#   --delimiter SEP    Field delimiter: 'tab' or any single char (default: auto-detect)
#   -h, --help         Show this help message
#   --keep-temp        Keep intermediate temporary files for debugging
#   --null STRING      String to treat as a null value (multiple allowed; default: common set of strings)
#   -o, --output PATH  Relative path to output folder. Will be created if needed. (REQUIRED)
#   -s, --schema PATH  Relative file path for the JSONSchema file (REQUIRED)
#   --skip-lines N     Number of header/preamble lines to skip (default: 0)
#   --summary-file     Output a summary file for the validation (default: disabled)
#
# Outputs (written to output folder):
#   <input_file>.valid                 - Rows that passed validation
#   <input_file>.invalid               - Rows that failed validation
#   <input_file>.validation-errors.tsv - Detailed per-field error report
#   <input_file>.summary.json          - Summary file for the validation
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

usage() {
    sed -n '3,/^# ----/p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ "${KEEP_TEMP:-0}" == "0" && -n "${TMPDIR_WORK:-}" && -d "${TMPDIR_WORK}" ]]; then
        rm -rf "${TMPDIR_WORK}"
    fi
}
trap cleanup EXIT

regex_clean() {
    local temp="$1" result=""
    for (( i=0; i<${#temp}; i++ )); do
        case "${temp:$i:1}" in
            '.') result="${result}\." ;;
            '^') result="${result}\^" ;;
            '$') result="${result}\\\$" ;;
            '*') result="${result}\*" ;;
            '+') result="${result}\+" ;;
            '?') result="${result}\?" ;;
            '(') result="${result}\(" ;;
            ')') result="${result}\)" ;;
            '[') result="${result}\[" ;; # closing bracket not escaped outside of blocks
            '{') result="${result}\{" ;; # closing bracket not escaped outside of blocks
            '\') result="${result}\\\\" ;;
            '|') result="${result}\|" ;;
            *) result="${result}${temp:$i:1}"
        esac
    done
    echo "${result}"
}

count_rows() {
    local f="$1"
    [[ -f "${f}" ]] || { echo "0"; return; }
    tail -n +2 "${f}" | wc -l | tr -d ' '
}

# -----------------------------------------------------------------------------
# dependency check
# -----------------------------------------------------------------------------

command -v qsv &>/dev/null || error "qsv is not installed or not on PATH. See https://github.com/dathere/qsv"

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------

INPUT_FILE=""
SCHEMA=""
SKIP_LINES=0
COMMENT_CHAR="#"
DELIMITER=""      # empty = auto-detect
KEEP_TEMP=0
OUTPUT_PATH=""
REGEX_NULL=""
SUMMARY_FILE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --comment)         COMMENT_CHAR="${2:?'--comment requires a value'}";  shift 2 ;;
        --delimiter)       DELIMITER="${2:?'--delimiter requires a value'}";   shift 2 ;;
        -h|--help)         usage 0 ;;
        --keep-temp)       KEEP_TEMP=1; shift ;;
        --null)
            REGEX_NULL="${REGEX_NULL}$(regex_clean "${2:?'--null requires a value'}")|"
            shift 2 ;;
        -o|--output)       OUTPUT_PATH="${2:?'--output requires a value'}";    shift 2 ;;
        -s|--schema)       SCHEMA="${2:?'--schema requires a value'}";         shift 2 ;;
        --skip-lines)      SKIP_LINES="${2:?'--skip-lines requires a value'}"; shift 2 ;;
        --summary-file)    SUMMARY_FILE=1; shift ;;
        -*)                error "Unknown option: $1" ;;
        *)
            if   [[ -z "${INPUT_FILE}" ]]; then INPUT_FILE="$1"
            else error "Unexpected argument: $1"
            fi
            shift ;;
    esac
done

[[ -n "${INPUT_FILE}"  ]] || error "No input file supplied. Run with --help for usage."
[[ -n "${SCHEMA}"      ]] || error "No JSONschema supplied. Run with --help for usage."
[[ -n "${OUTPUT_PATH}" ]] || error "No output path supplied. Run with --help for usage."
[[ -f "${INPUT_FILE}"  ]] || error "Input file not found: ${INPUT_FILE}"

# Schema may be a local file or a URL - only check existence for local paths
if [[ "${SCHEMA}" != http* ]]; then
    [[ -f "${SCHEMA}" ]] || error "Schema file not found: ${SCHEMA}"
fi

# strip trailing `/` from the output path
while [[ "${OUTPUT_PATH}" == */ ]]; do OUTPUT_PATH="${OUTPUT_PATH%/}"; done

# strip trailing `||` from the regex null string
if [[ -n "${REGEX_NULL}" ]]; then REGEX_NULL="${REGEX_NULL%\|}"; fi

# -----------------------------------------------------------------------------
# resolve delimiter flag
# -----------------------------------------------------------------------------

DELIM_FLAG=()
if [[ -n "${DELIMITER}" ]]; then
    if [[ "${DELIMITER}" == "tab" || "${DELIMITER}" == $'\t' ]]; then
        DELIM_FLAG=(--delimiter $'\t')
    else
        DELIM_FLAG=(--delimiter "${DELIMITER}")
    fi
else
    # Auto-detect: treat .tsv files as tab-delimited; otherwise sniff via qsv
    if [[ "${INPUT_FILE,,}" == *.tsv ]]; then
        DELIM_FLAG=(--delimiter $'\t')
    fi
    # If still empty, qsv will default to comma — fine for .csv
fi

# -----------------------------------------------------------------------------
# working directory
# -----------------------------------------------------------------------------

TMPDIR_WORK=$(mktemp -d)
NORMALIZED="${TMPDIR_WORK}/normalized.csv"

info "Input file : ${INPUT_FILE}"
info "Schema     : ${SCHEMA}"
info "Temp dir   : ${TMPDIR_WORK}"

# -----------------------------------------------------------------------------
# STEP 1: Normalize with qsv input
#   --comment         skip lines beginning with the comment character
#   --trim-headers    strip surrounding whitespace from header names
#   --trim-fields     strip surrounding whitespace from every field value
#   --encoding-errors replace invalid UTF-8 sequences with the replacement char
#   --skip-lines N    skip N non-comment preamble/header lines before the CSV header
# -----------------------------------------------------------------------------

info "Step 1/3: Normalizing input (comments, whitespace, encoding)..."

SKIP_FLAG=()
if [[ "${SKIP_LINES}" =~ ^[0-9]+$ ]] && (( SKIP_LINES > 0 )); then
    SKIP_FLAG=(--skip-lines "${SKIP_LINES}")
elif [[ "${SKIP_LINES}" != "0" ]]; then
    error "--skip-lines must be a non-negative integer"
fi

qsv input \
    "${DELIM_FLAG[@]}" \
    --comment "${COMMENT_CHAR}" \
    --trim-headers \
    --trim-fields \
    --encoding-errors replace \
    "${SKIP_FLAG[@]}" \
    "${INPUT_FILE}" \
    --output "${NORMALIZED}"

info "           -> wrote $(qsv count "${NORMALIZED}") data rows to normalized file"

# -----------------------------------------------------------------------------
# STEP 2: Null-value replacement with qsv replace
#
# Pattern covers common null representations:
#   • Bare words : NULL, null, Null, NA, N/A, na, n/a, None, none,
#                  NaN, nan, NIL, nil, missing, MISSING, unknown, UNKNOWN
#   • Punctuation: -  --  ---  ...  ..
#   • Quoted      : already empty after trim; the pattern also catches
#                   strings that were literally written as "" or ''
#
# The regex is anchored (^ ...$) so it only matches cells whose *entire*
# content is one of these tokens - partial matches are left untouched.
# Replacement is the empty string, making the cell truly empty for the
# JSON Schema "required" / "minLength" checks.
# -----------------------------------------------------------------------------

info "Step 2/3: Replacing null-like values with empty string..."

if [[ -z "${REGEX_NULL}" ]]; then
    NULL_PATTERN='^([Nn][Uu][Ll][Ll]|[Nn][Aa][Nn]|[Nn][Ii][Ll]|[Nn][Oo][Nn][Ee]|[Nn][/]?[Aa]|[Mm][Ii][Ss][Ss][Ii][Nn][Gg]|[Uu][Nn][Kk][Nn][Oo][Ww][Nn]|-{1,3}|\.{2,3}|""|'"''"')$'
else
    NULL_PATTERN="^(${REGEX_NULL})\$"
fi

NULL_REPLACED="${TMPDIR_WORK}/null_replaced.csv"

qsv replace \
    --select '1-' \
    "${NULL_PATTERN}" \
    '' \
    "${NORMALIZED}" \
    --output "${NULL_REPLACED}" \
    --not-one \
    -i

info "           -> null replacement complete"

# -----------------------------------------------------------------------------
# STEP 3: Validate against the JSONschema
#
# qsv validate produces three sibling files next to the output path:
#   .valid                 - every row that passed
#   .invalid               - every row that failed
#   .validation-errors.tsv - row_number / field / error for each failure
#
# We direct output to a file in the temp dir then copy results back so the
# report files sit alongside the *original* input file, which is more useful.
# -----------------------------------------------------------------------------

info "Step 3/3: Validating against schema: ${SCHEMA}..."

VALIDATE_OUT="${TMPDIR_WORK}/validated.csv"
cp "${NULL_REPLACED}" "${VALIDATE_OUT}"
# qsv validate exit codes: 0 = all valid, 1 = some invalid, other = error
set +e
qsv validate \
    "${VALIDATE_OUT}" \
    "${SCHEMA}" \
    2>&1
VALIDATE_EXIT=$?
set -e

# -----------------------------------------------------------------------------
# collect and report results
# -----------------------------------------------------------------------------

BASE="${INPUT_FILE}"
if [[ "${OUTPUT_PATH}" != "." ]]; then
    mkdir -p "${OUTPUT_PATH}"
    BASE="${OUTPUT_PATH}/${BASE##*/}"
fi

# copy out results
INVALID_PATH=""
ERRORS_PATH=""
case "${VALIDATE_EXIT}" in
    0)
        src="${TMPDIR_WORK}/validated.csv"
        [[ -f "${src}" ]] && cp "${src}" "${BASE}.valid"
        VALID_PATH="${BASE}.valid"
        ;;
    1)
        for ext in valid invalid "validation-errors.tsv"; do
            src="${TMPDIR_WORK}/validated.csv.${ext}"
            [[ -f "${src}" ]] && cp "${src}" "${BASE}.${ext}"
        done
        VALID_PATH="${BASE}.valid"
        INVALID_PATH="${BASE}.invalid"
        ERRORS_PATH="${BASE}.validation-errors.tsv"
        ;;
esac

case "${VALIDATE_EXIT}" in
    0)  STATUS_MESSAGE="All records are VALID." ;;
    1)  STATUS_MESSAGE="Validation complete with errors." ;;
    *)  STATUS_MESSAGE="qsv validate exited with unexpected code ${VALIDATE_EXIT}. Check schema and input." ;;
esac

VALID_COUNT=$(count_rows "${BASE}.valid")
INVALID_COUNT=$(count_rows "${BASE}.invalid")

if [[ "${SUMMARY_FILE:-0}" == "1" ]]; then
    # write a JSON summary file with validation stats
    cat << EOF > "${BASE}.summary.json"
{
  "status_code": ${VALIDATE_EXIT},
  "status_message": "${STATUS_MESSAGE}",
  "valid_rows": ${VALID_COUNT},
  "invalid_rows": ${INVALID_COUNT},
  "valid_records_file": "${VALID_PATH}",
  "invalid_records_file": "${INVALID_PATH}",
  "errors_file": "${ERRORS_PATH}"
}
EOF
fi

echo ""
case "${VALIDATE_EXIT}" in
    0)
        info "✅  All records are VALID."
        ;;
    1)
        warn "⚠️   Validation complete with errors."
        warn "    Valid rows   : ${VALID_COUNT}"
        warn "    Invalid rows : ${INVALID_COUNT}"
        info "Output files:"
        info "    ${VALID_FILE}"
        info "    ${INVALID_FILE}"
        info "    ${ERRORS_FILE}"
        ;;
    *)
        error "qsv validate exited with unexpected code ${VALIDATE_EXIT}. Check schema and input."
        ;;
esac

exit "${VALIDATE_EXIT}"
