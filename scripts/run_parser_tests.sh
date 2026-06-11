#!/bin/sh
# Runs the jai_parser dump tool over every fixture in modules/jai_parser/tests/
# and reports files that crash, hang (60s timeout), or spam parse errors.
# Usage: scripts/run_parser_tests.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER_DIR="$ROOT/modules/jai_parser"
PARSER_BIN="$PARSER_DIR/cmd/bin/jai_parser"

if [ ! -x "$PARSER_BIN" ]; then
    echo "Parser tool not built. Run: cd $PARSER_DIR/cmd && jai build.jai" >&2
    exit 2
fi

run_with_timeout() {
    # perl-based timeout: portable on macOS where coreutils' timeout may be absent
    perl -e '
        my $timeout = shift @ARGV;
        my $pid = fork;
        if (!$pid) { exec @ARGV or exit 127; }
        local $SIG{ALRM} = sub { kill "KILL", $pid; waitpid $pid, 0; exit 124; };
        alarm $timeout;
        waitpid $pid, 0;
        exit($? >> 8);
    ' "$@"
}

pass=0
fail=0
failed_files=""

cd "$PARSER_DIR" || exit 2

for f in tests/*.jai; do
    out=$(run_with_timeout 60 "$PARSER_BIN" "$f" 2>&1)
    code=$?
    status="ok"
    if [ $code -eq 124 ]; then
        status="TIMEOUT"
    elif [ $code -ne 0 ]; then
        status="EXIT $code"
    elif printf '%s' "$out" | grep -qiE 'invalid operator|unexpected token|parse error'; then
        status="PARSE ERRORS"
    fi

    if [ "$status" = "ok" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed_files="$failed_files\n  $f ($status)"
        printf 'FAIL %s (%s)\n' "$f" "$status"
        printf '%s\n' "$out" | grep -iE 'invalid operator|unexpected token|parse error|signal' | head -3 | sed 's/^/       /'
    fi
done

echo
echo "parser tests: $pass passed, $fail failed"
[ $fail -eq 0 ]
