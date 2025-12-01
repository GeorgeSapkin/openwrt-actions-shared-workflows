#!/bin/bash

# Disable `Expressions don't expand in single quotes, use double quotes for
# that.` which is as intended.
# shellcheck disable=SC2016

# Based on https://openwrt.org/submitting-patches#submission_guidelines
# Hard limit is arbitrary
MAX_SUBJECT_LEN_HARD=60
MAX_SUBJECT_LEN_SOFT=50
MAX_BODY_LINE_LEN=75

INDENT_MD='    '
INDENT_TERM='       '

GITHUB_NOREPLY_EMAIL='@users.noreply.github.com'
WEBLATE_EMAIL='hosted@weblate.org'

EMOJI_WARN=':large_orange_diamond:'
EMOJI_FAIL=':x:'

FAIL=0

# Use these global vars to improve header creation readability
COMMIT=""
HEADER_SET=0

REPO_PATH=${1:+-C "$1"}
# shellcheck disable=SC2206
REPO_PATH=($REPO_PATH)

if [ -f 'workflow_context/.github/scripts/ci_helpers.sh' ]; then
	source workflow_context/.github/scripts/ci_helpers.sh
else
	source .github/scripts/ci_helpers.sh
fi

# output_xxx write to GitHub Actions output to be later posted to a PR
# status_xxx write to terminal

output() {
	[ -f "$GITHUB_OUTPUT" ] || return

	echo "$1" >> "$GITHUB_OUTPUT"
}

output_header() {
	[ "$HEADER_SET" = 0 ] || return

	[ -f "$GITHUB_OUTPUT" ] || return

	cat >> "$GITHUB_OUTPUT" <<-HEADER

	### Commit $COMMIT

	HEADER

	HEADER_SET=1
}

output_raw() {
	output "$INDENT_MD$1"
	echo "$INDENT_TERM$1"
}

output_details() {
	local actual="${1:-}"
	local expected="${2:-}"

	if [ -n "$actual" ]; then
		output_raw "Actual: $actual"
	fi

	if [ -n "$expected" ]; then
		output_raw "Expected: $expected"
	fi
}

output_pass() {
	local msg="$1"
	local reason="${2:-}"

	# Don't actually output anything to actions output
	status_pass "$msg"
	if [ -n "$reason" ]; then
		echo "${INDENT_TERM}Reason: $reason"
	fi
}

output_warn() {
	local msg="$1"
	local actual="${2:-}"
	local expected="${3:-}"

	output_header
	output "- $EMOJI_WARN $msg"
	status_warn "$msg"
	output_details "$actual" "$expected"
}

output_fail() {
	local msg="$1"
	local actual="${2:-}"
	local expected="${3:-}"

	output_header
	output "- $EMOJI_FAIL $msg"
	status_fail "$msg"
	output_details "$actual" "$expected"

	FAIL=1
}

output_skip() {
	local msg="$1"
	local reason="${2:-}"

	# Don't actually output anything to actions output
	status_skip "$msg"
	if [ -n "$reason" ]; then
		echo "${INDENT_TERM}Reason: $reason"
	fi
}

output_split_fail() {
	split_fail "$1" "$2" "${INDENT_TERM}"
	[ -f "$GITHUB_OUTPUT" ] || return
	printf "${INDENT_MD}\$\\\textsf{%s\\color{red}{%s}}\$\n" "${2:0:$1}" "${2:$1}" >> "$GITHUB_OUTPUT"
}

legend() {
	info 'Legend:'
	status_pass 'Check passed'
	echo "${INDENT_TERM}Reason: (optional) explanation"
	status_warn "Check passed with a warning and won't fail the job"
	echo "${INDENT_TERM}Actual: (optional) actual value or reason"
	echo "${INDENT_TERM}Expected: (optional) expected value"
	status_fail 'Check failed and will fail the job'
	echo "${INDENT_TERM}Actual: (optional) actual value or reason"
	echo "${INDENT_TERM}Expected: (optional) expected value"
	status_skip "Check skipped, due to another check or workflow configuration and won't affect the job"
	echo -e "${INDENT_TERM}Reason: (optional) explanation\n"
}

is_main_branch() {
	[ "$1" = "main" ] || [ "$1" = "master" ]
}

is_stable_branch() {
	! is_main_branch "$1"
}

is_github_noreply() {
	echo "$1" | grep -qF "$GITHUB_NOREPLY_EMAIL"
}

is_weblate() {
	echo "$1" | grep -iqF "$WEBLATE_EMAIL"
}

exclude_weblate() {
	[ "$EXCLUDE_WEBLATE" = 'true' ]
}

check_name() {
	local type="$1"
	local name="$2"

	msg="$type name seems OK"
	# Pattern \S\+\s\+\S\+ matches >= 2 names i.e. 3 and more e.g. "John Von
	# Doe" also match
	if echo "$name" | grep -q '\S\+\s\+\S\+'; then
		status_pass "$msg"
	# Pattern \S\+ matches single names, typical of nicknames or handles
	elif echo "$name" | grep -q '\S\+'; then
		output_warn "$msg" "$name seems to be a nickname or an alias"
	else
		output_fail "$msg" "$name" "must be either a real name 'firstname lastname' or a nickname/alias/handle"
	fi
}

check_email() {
	local type="$1"
	local email="$2"

	local msg="$type email cannot be a GitHub noreply email"
	if is_github_noreply "$email"; then
		output_fail "$msg" "$email"
	else
		status_pass "$msg"
	fi
}

check_subject() {
	local subject="$1"
	local is_prefix_ok=0
	local msg
	local skip_reason

	if exclude_weblate && echo "$subject" | grep -iq -e '^Translated using Weblate.*' -e '^Added translation using Weblate.*'; then
		skip_reason='authored by Weblate'
	elif echo "$subject" | grep -q -e '^Revert '; then
		skip_reason='revert commit'
	fi

	msg='Commit subject line MUST start with `<package name>: `'
	if [ -n "$skip_reason" ]; then
		output_skip	"$msg" "$skip_reason"
	elif echo "$subject" | grep -q -e '^[0-9A-Za-z,+/_-]\+: '; then
		status_pass "$msg"
		is_prefix_ok=1
	else
		output_fail "$msg"
	fi

	msg='First word after prefix in subject should not be capitalized'
	if [ -n "$skip_reason" ]; then
		output_skip	"$msg" "$skip_reason"
	elif [ "$is_prefix_ok" = 0 ]; then
		output_skip	"$msg" 'missing prefix'
	elif echo "$subject" | grep -q -e '^[0-9A-Za-z,+/_-]\+: [A-Z]'; then
		output_fail "$msg"
	else
		status_pass "$msg"
	fi

	msg='Commit subject line should not end with a period'
	if [ -n "$skip_reason" ]; then
		output_skip "$msg" "$skip_reason"
	elif echo "$subject" | grep -q '\.$'; then
		output_fail "$msg"
	else
		status_pass "$msg"
	fi

	# Check subject length first for hard limit which results in an error and
	# otherwise for a soft limit which results in a warning. Show soft limit in
	# either case.
	msg="Commit subject length is max $MAX_SUBJECT_LEN_HARD characters (recommended max $MAX_SUBJECT_LEN_SOFT)"
	if [ -n "$skip_reason" ]; then
		output_skip "$msg" "$skip_reason"
	elif [ ${#subject} -gt "$MAX_SUBJECT_LEN_HARD" ]; then
		output_fail "$msg" "subject is ${#subject} characters long"
		output_split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
	elif [ ${#subject} -gt "$MAX_SUBJECT_LEN_SOFT" ]; then
		output_warn "$msg" "subject is ${#subject} characters long"
		output_split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
	else
		status_pass "$msg"
	fi
}

check_body() {
	local body="$1"
	local sob="$2"
	local is_weblate="${3:-}"
	local is_signoff_missing=0
	local msg
	local skip_reason

	msg='`Signed-off-by` matches author'
	if exclude_weblate && [ "$is_weblate" = 1 ]; then
		skip_reason='authored by Weblate'
		output_skip "$msg" "$skip_reason"
	elif echo "$body" | grep -qF "$sob"; then
		status_pass "$msg"
	else
		skip_reason="missing or doesn't match author"
		is_signoff_missing=1
		output_fail "$msg" "$skip_reason" "\`$sob\`"
	fi

	msg='`Signed-off-by` cannot be a GitHub noreply email'
	if [ -n "$skip_reason" ]; then
		output_skip "$msg" "$skip_reason"
		if [ "$is_signoff_missing" = 1 ]; then
			skip_reason=''
		fi
	elif is_github_noreply "$body"; then
		output_fail "$msg"
	else
		status_pass "$msg"
	fi

	msg='Commit message exists'
	if echo "$body" | grep -v "Signed-off-by:" | grep -q '[^[:space:]]'; then
		status_pass "$msg"
	else
		output_fail "$msg"
		skip_reason='missing commit message'
	fi

	msg="Commit body lines are $MAX_BODY_LINE_LEN characters or less"
	if [ -z "$skip_reason" ]; then
		local body_line_too_long=0
		local line_num=0
		while IFS= read -r line; do
			line_num=$((line_num + 1))
			if [ ${#line} -gt "$MAX_BODY_LINE_LEN" ]; then
				output_warn "$msg" "line $line_num is ${#line} characters long"
				output_split_fail "$MAX_BODY_LINE_LEN" "$line"
				body_line_too_long=1
			fi
		done <<< "$body"
		if [ "$body_line_too_long" = 0 ]; then
			status_pass "$msg"
		fi
	else
		output_skip "$msg" "$skip_reason"
	fi

	msg='Commit to stable branch is marked as cherry-picked'
	if is_stable_branch "$BRANCH"; then
		if echo "$body" | grep -qF "(cherry picked from commit"; then
			status_pass "$msg"
		else
			output_warn "$msg"
		fi
	else
		output_skip "$msg" "\`$BRANCH\` branch"
	fi
}

main() {
	local author_email
	local author_name
	local body
	local commit
	local committer_email
	local committer_name
	local msg
	local subject

	# Initialize GitHub actions output
	output 'content<<EOF'

	echo 'Something broken? Consider providing feedback:'
	echo -e 'https://github.com/openwrt/actions-shared-workflows/issues\n'

	if exclude_weblate; then
		warn 'Weblate exceptions are enabled'
	else
		echo 'Weblate exceptions are disabled'
	fi
	echo

	legend

	info "Checking PR #$PR_NUMBER"
	msg='Pull request should come from a feature branch'
	if is_main_branch "$HEAD_BRANCH"; then
		output_fail "$msg" "\`$HEAD_BRANCH\` branch"
	else
		output_pass "$msg" "\`$HEAD_BRANCH\` branch"
	fi
	echo

	for commit in $(git "${REPO_PATH[@]}" rev-list HEAD ^origin/"$BRANCH"); do
		HEADER_SET=0
		COMMIT="$commit"

		git "${REPO_PATH[@]}" log -1 --color --pretty=full "$commit"
		echo

		msg='Pull request should not include merge commits'
		if git "${REPO_PATH[@]}" show --format='%P' -s "$commit" | grep -qF ' '; then
			output_fail "$msg"

			# No need to check anything else, since this is a merge commit
			echo
			continue
		else
			status_pass "$msg"
		fi

		author_name="$(git "${REPO_PATH[@]}" show -s --format=%aN "$commit")"
		committer_name="$(git "${REPO_PATH[@]}" show -s --format=%cN "$commit")"
		check_name 'Author' "$author_name"
		check_name 'Committer' "$committer_name"

		author_email="$(git "${REPO_PATH[@]}" show -s --format='%aE' "$commit")"
		committer_email="$(git "${REPO_PATH[@]}" show -s --format='%cE' "$commit")"
		check_email 'Author' "$author_email"
		check_email 'Committer' "$committer_email"

		subject="$(git "${REPO_PATH[@]}" show -s --format=%s "$commit")"
		check_subject "$subject"

		body="$(git "${REPO_PATH[@]}" show -s --format=%b "$commit")"
		sob="$(git "${REPO_PATH[@]}" show -s --format='Signed-off-by: %aN <%aE>' "$commit")"
		check_body "$body" "$sob" "$(is_weblate "$author_email" && echo 1)"

		echo
	done

	output 'EOF'

	exit "$FAIL"
}

main
