# Exit is an effect (roc:cli/exit), so it is the only way an app names its own
# status — and nothing else in either repo exercises it. b8's upstream examples
# cannot: basic-cli had no such call.
source ../lib.sh
new_project
build_app app.roc exiter
EXITER=$(bin exiter)
# `|| x=$?`, because a nonzero exit is the point here and `set -e` would
# otherwise kill the script before the status could be read.
plain=0; "$EXITER" || plain=$?
coded=0; "$EXITER" one || coded=$?
[[ "$plain" == 0 ]] || { echo "FAIL: returning Ok gave status $plain, want 0"; exit 1; }
[[ "$coded" == 7 ]] || { echo "FAIL: Cli.exit!(7) gave status $coded, want 7"; exit 1; }
echo "ok: exit is an effect — Ok is 0, Cli.exit!(7) is 7"
