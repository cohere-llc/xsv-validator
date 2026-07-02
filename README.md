# xsv-validator

[![License](https://img.shields.io/github/license/cohere-llc/xsv-validator.svg)](https://github.com/cohere-llc/xsv-validator/blob/main/LICENSE)
[![Tests](https://github.com/cohere-llc/xsv-validator/actions/workflows/docker.yml/badge.svg)](https://github.com/cohere-llc/xsv-validator/actions/workflows/docker.yml)

CSV/TSV Validator CLI tool: Normalize and validate a TSV/CSV file using qsv

## Usage

### Basic Usage
```sh
./xsv-validate.sh <input_file> <schema.json> [options]
```

## Arguments:
```
   <input_file>     Path to the CSV or TSV file to validate
   <schema.json>    Path to (or URL of) a JSONschema file
```

## Options:
```
   --skip-lines N   Number of header/preamble lines to skip (default: 0)
   --comment CHAR   Comment character to strip (default: #)
   --delimiter SEP  Field delimiter: 'tab' or any single char (default: auto-detect)
   --keep-temp      Keep intermediate temporary files for debugging
   -h, --help       Show this help message
```
## Outputs (written alongside `<input_file>`):
```
   <input_file>.valid                 - Rows that passed validation
   <input_file>.invalid               - Rows that failed validation
   <input_file>.validation-errors.tsv - Detailed per-field error report
```
