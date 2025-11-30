#!/bin/bash

# Based on https://openwrt.org/submitting-patches#submission_guidelines
# Hard limit is arbitrary
MAX_SUBJECT_LEN_HARD=60
MAX_SUBJECT_LEN_SOFT=50
MAX_BODY_LINE_LEN=75

INDENT_MD='    '
INDENT_TERM='       '

WEBLATE_EMAIL="<hosted@weblate.org>"

EMOJI_WARN=':large_orange_diamond:'
EMOJI_FAIL=':x:'

RET=0

# Use these global vars to improve header creation readability
COMMIT=""
HEADER_SET=0

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
	output_header
	output "$1"
	echo "   $1"
}

output_details() {
	local actual="${1:-}"
	local expected="${2:-}"

	if [ -n "$actual" ]; then
		output_raw "${INDENT_MD}Actual: $actual"
	fi

	if [ -n "$expected" ]; then
		output_raw "${INDENT_MD}Expected: $expected"
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
}

output_skip() {
	local msg="$1"
	local reason="${2:-}"

	# Don't actually output anything, but I ran out of names
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

is_main_branch() {
	[ "$1" = "main" ] || [ "$1" = "master" ]
}

is_stable_branch() {
	[ "$1" != "main" ] && [ "$1" != "master" ]
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
		status_pass "$msg" "$name"
	# Pattern \S\+ matches single names, typical of nicknames or handles
	elif echo "$name" | grep -q '\S\+'; then
		output_warn "$msg" "$name seems to be a nickname or an alias"
	else
		output_fail "$msg" "$name" "must be either a real name 'firstname lastname' or a nickname/alias/handle"
		RET=1
	fi
}

check_email() {
	local type="$1"
	local email="$2"

	local msg="$type email cannot be a GitHub noreply email"
	if echo "$email" | grep -qF "@users.noreply.github.com"; then
		output_fail "$msg" "$email"
		RET=1
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
		RET=1
	fi

	msg='First word after prefix in subject should not be capitalized'
	if [ -n "$skip_reason" ]; then
		output_skip	"$msg" "$skip_reason"
	elif [ "$is_prefix_ok" = 0 ]; then
		output_skip	"$msg" 'missing prefix'
	elif echo "$subject" | grep -q -e '^[0-9A-Za-z,+/_-]\+: [A-Z]'; then
		output_fail "$msg"
		RET=1
	else
		status_pass "$msg"
	fi

	msg='Commit subject line should not end with a period'
	if [ -n "$skip_reason" ]; then
		output_skip "$msg" "$skip_reason"
	elif echo "$subject" | grep -q '\.$'; then
		output_fail "$msg"
		RET=1
	else
		status_pass "$msg"
	fi

	# Check subject length first for hard limit which results in an error and
	# otherwise for a soft limit which results in a warning. Show soft limit in
	# either case.
	msg="Commit subject line is $MAX_SUBJECT_LEN_SOFT characters or less"
	if [ -n "$skip_reason" ]; then
		output_skip "$msg" "$skip_reason"
	elif [ ${#subject} -gt "$MAX_SUBJECT_LEN_HARD" ]; then
		output_fail "$msg" "${#subject}"
		output_split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
		RET=1
	elif [ ${#subject} -gt "$MAX_SUBJECT_LEN_SOFT" ]; then
		output_warn "$msg" "${#subject}"
		output_split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
		# Don't mark this as a return failure
	else
		status_pass "$msg"
	fi
}

check_body() {
	local body="$1"
	local sob="$2"
	local author_email="$3"
	local msg
	local skip_reason

	msg='`Signed-off-by` matches author'
	if echo "$body" | grep -qF "$sob"; then
		status_pass "$msg"
	elif exclude_weblate && is_weblate "$author_email"; then
		# Don't append to the workflow output, since this is more of an internal
		# warning.
		output_skip "$msg"
	else
		output_fail "$msg" "missing or doesn't match author" "\`$sob\`"
		RET=1
	fi

	msg='`Signed-off-by` email is not a GitHub noreply email'
	if echo "$body" | grep -qF "@users.noreply.github.com"; then
		output_fail "$msg"
		RET=1
	else
		status_pass "$msg"
	fi

	msg='Commit message exists'
	if echo "$body" | grep -v "Signed-off-by:" | grep -q '[^[:space:]]'; then
		status_pass "$msg"
	else
		output_fail "$msg"
		skip_reason='missing commit message'
		RET=1
	fi

	msg="Commit body lines are $MAX_BODY_LINE_LEN characters or less"
	if exclude_weblate && is_weblate "$author_email"; then
		skip_reason='authored by Weblate'
	fi

	if [ -z "$skip_reason" ]; then
		local body_line_too_long=0
		local line_num=0
		while IFS= read -r line; do
			line_num=$((line_num + 1))
			if [ ${#line} -gt "$MAX_BODY_LINE_LEN" ]; then
				output_warn "$msg" "${#line}"
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
		output_skip "$msg" 'main branch'
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

	if exclude_weblate; then
		warn 'Weblate exceptions are enabled'
	else
		echo 'Weblate exceptions are disabled'
	fi
	echo

	for commit in $(git rev-list HEAD ^origin/"$BRANCH"); do
		HEADER_SET=0
		COMMIT="$commit"

		info "=== Checking commit '$commit'"

		msg='Pull request should not include merge commits'
		if git show --format='%P' -s "$commit" | grep -qF ' '; then
			output_fail "$msg"
			RET=1

			# No need to check anything else, since this is a merge commit
			info "=== Done checking commit '$commit'"
			echo
			continue
		else
			status_pass "$msg"
		fi

		author_name="$(git show -s --format=%aN "$commit")"
		committer_name="$(git show -s --format=%cN "$commit")"
		check_name 'Author' "$author_name"
		check_name 'Committer' "$committer_name"

		author_email="$(git show -s --format='<%aE>' "$commit")"
		committer_email="$(git show -s --format='<%cE>' "$commit")"
		check_email 'Author' "$author_email"
		check_email 'Committer' "$committer_email"

		subject="$(git show -s --format=%s "$commit")"
		echo
		info 'Checking subject:'
		echo "$subject"
		check_subject "$subject"

		body="$(git show -s --format=%b "$commit")"
		sob="$(git show -s --format='Signed-off-by: %aN <%aE>' "$commit")"
		echo
		info 'Checking body:'
		echo "$body"
		check_body "$body" "$sob" "$author_email"

		info "=== Done checking commit '$commit'"
		echo
	done

	output 'EOF'

	exit $RET
}

main
