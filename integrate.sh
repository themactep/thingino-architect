#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TOOL_DIR=$SCRIPT_DIR
REPO=${THINGINO_REPO:-"$SCRIPT_DIR/../firmware/master"}
WITH_OCR=0
REFRESH_BASELINE=0
DRY_RUN=0
FORCE=0

usage() {
	cat <<'EOF'
Usage: integrate.sh [options]

Install thingino-arch into a Thingino firmware checkout.

Options:
  --repo PATH            Firmware checkout (default: $THINGINO_REPO or ../firmware/master)
  --tool PATH            thingino-arch source directory (default: script directory)
  --with-ocr             Also install the optional OCR review workflow
  --refresh-baseline     Regenerate tools/thingino-arch/baseline.json
  --force                Overwrite existing workflow files
  --dry-run              Print actions without changing anything
  -h, --help             Show this help

The script never commits. Review the copied files and commit them yourself.
EOF
}

while [ "$#" -gt 0 ]; do
	case $1 in
		--repo)
			[ "$#" -ge 2 ] || {
				echo "error: --repo needs a value" >&2
				exit 2
			}
			REPO=$2
			shift 2
			;;
		--tool)
			[ "$#" -ge 2 ] || {
				echo "error: --tool needs a value" >&2
				exit 2
			}
			TOOL_DIR=$2
			shift 2
			;;
		--with-ocr)
			WITH_OCR=1
			shift
			;;
		--refresh-baseline)
			REFRESH_BASELINE=1
			shift
			;;
		--force)
			FORCE=1
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "error: unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

[ -d "$REPO" ] || {
	echo "error: firmware checkout not found: $REPO" >&2
	exit 1
}
[ -d "$TOOL_DIR" ] || {
	echo "error: tool directory not found: $TOOL_DIR" >&2
	exit 1
}

REPO=$(CDPATH='' cd -- "$REPO" && pwd)
TOOL_DIR=$(CDPATH='' cd -- "$TOOL_DIR" && pwd)
DEST="$REPO/tools/thingino-arch"

[ -f "$REPO/thingino.mk" ] && [ -d "$REPO/package" ] || {
	echo "error: $REPO is not a Thingino firmware tree" >&2
	exit 1
}
[ -f "$TOOL_DIR/bin/thingino-arch" ] && [ -d "$TOOL_DIR/lib/thingino_arch" ] || {
	echo "error: $TOOL_DIR is not a thingino-arch source tree" >&2
	exit 1
}
command -v ruby >/dev/null 2>&1 || {
	echo "error: ruby is required" >&2
	exit 1
}

run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '+ %s\n' "$*"
	else
		"$@"
	fi
}

install_workflow() {
	if [ -f "$2" ]; then
		if cmp -s "$1" "$2"; then
			echo "unchanged: $2"
			return
		fi
		if [ "$FORCE" -eq 0 ]; then
			echo "error: $2 already exists and differs; use --force to replace it" >&2
			exit 1
		fi
	fi
	run cp "$1" "$2"
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "would install: $2"
	else
		echo "installed: $2"
	fi
}

preflight_workflow() {
	if [ -f "$2" ] && ! cmp -s "$1" "$2" && [ "$FORCE" -eq 0 ]; then
		echo "error: $2 already exists and differs; use --force to replace it" >&2
		exit 1
	fi
}

preflight_workflow "$TOOL_DIR/ci/architecture-check.yml" "$REPO/.github/workflows/architecture-check.yml"
if [ "$WITH_OCR" -eq 1 ]; then
	preflight_workflow "$TOOL_DIR/ci/ocr-review.yml" "$REPO/.github/workflows/ocr-architecture-review.yml"
fi

echo "Installing thingino-arch into $DEST"
run mkdir -p "$DEST" "$REPO/.github/workflows"

for directory in bin lib architecture rules prompts doc ci; do
	run rm -rf "$DEST/$directory"
	run cp -R "$TOOL_DIR/$directory" "$DEST/$directory"
done
run cp "$TOOL_DIR/README.md" "$DEST/README.md"
run chmod +x "$DEST/bin/thingino-arch"

if [ ! -f "$DEST/baseline.json" ] || [ "$REFRESH_BASELINE" -eq 1 ]; then
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "Would generate baseline from $REPO"
	else
		echo "Generating baseline from $REPO"
	fi
	run "$DEST/bin/thingino-arch" check --repo "$REPO" --write-baseline "$DEST/baseline.json"
else
	echo "Keeping existing baseline: $DEST/baseline.json"
fi

install_workflow "$TOOL_DIR/ci/architecture-check.yml" "$REPO/.github/workflows/architecture-check.yml"

if [ "$WITH_OCR" -eq 1 ]; then
	install_workflow "$TOOL_DIR/ci/ocr-review.yml" "$REPO/.github/workflows/ocr-architecture-review.yml"
fi

if [ "$DRY_RUN" -eq 0 ]; then
	echo
	set +e
	check_output=$("$DEST/bin/thingino-arch" check --repo "$REPO" --baseline "$DEST/baseline.json" --format text)
	check_status=$?
	set -e
	if [ "$check_status" -eq 0 ]; then
		printf '%s\n' "$check_output" | tail -n 1
	else
		printf '%s\n' "$check_output"
		echo "warning: the installed smoke check exited with status $check_status; review the output above before committing" >&2
	fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
	completion="Dry run complete."
else
	completion="Integration complete."
fi

cat <<EOF

$completion

Next:
  1. Review and commit tools/thingino-arch and .github/workflows/architecture-check.yml.
  2. Regenerate the baseline only after intentional fixes:
     $DEST/bin/thingino-arch check --repo "$REPO" --write-baseline "$DEST/baseline.json"
  3. Optional OCR workflow:
     - rerun this script with --with-ocr
     - configure OCR_LLM_URL, OCR_LLM_AUTH_TOKEN, OCR_LLM_MODEL, and OCR_LLM_USE_ANTHROPIC
EOF
